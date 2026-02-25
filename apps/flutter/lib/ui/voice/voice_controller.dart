import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/deepgram_stt.dart';
import '../../services/elevenlabs_tts.dart';
import '../../services/openclaw_client.dart';
import 'voice_error.dart';
import 'voice_models.dart';

typedef VoiceToastCallback = void Function(String message, {bool isError});

class VoiceController {
  VoiceController({this.onToast}) {
    _listenToStt();
  }

  final DeepgramStt _stt = DeepgramStt();
  final OpenClawClient _llm = OpenClawClient();
  final ElevenLabsTts _tts = ElevenLabsTts();

  final ValueNotifier<VoiceViewState> state = ValueNotifier(
    VoiceViewState.initial(),
  );

  final VoiceToastCallback? onToast;

  bool _processingTurn = false;
  String _lastHeardTranscript = '';
  StreamSubscription<String>? _transcriptSub;

  void _setState(VoiceViewState next) {
    state.value = next;
  }

  void _listenToStt() {
    _transcriptSub = _stt.transcripts.listen((event) async {
      final current = state.value;

      if (event == '__RECONNECTING__') {
        if (current.voiceState != VoiceState.idle) {
          _setState(
            current.copyWith(
              voiceState: VoiceState.reconnecting,
              statusText: 'Reconnecting...',
            ),
          );
        }
        return;
      }

      if (event == '__RECONNECTED__') {
        if (current.voiceState != VoiceState.idle) {
          _setState(
            current.copyWith(
              voiceState: VoiceState.listening,
              statusText: 'Listening...',
            ),
          );
          onToast?.call('Back online ✓', isError: false);
        }
        return;
      }

      if (event == '__STT_FAILED__') {
        const err = OcError(
          message: 'Speech recognition unavailable',
          hint: 'Deepgram couldn\'t reconnect. Check your key in Settings.',
          needsSettings: true,
          fatal: true,
        );
        _setState(
          state.value.copyWith(
            voiceState: VoiceState.error,
            statusText: err.message,
            errorInfo: err,
          ),
        );
        return;
      }

      if (event == '__SPEECH_STARTED__') {
        if (state.value.voiceState == VoiceState.speaking) {
          await _handleBargeIn();
        }
        return;
      }

      if (event.startsWith('__SPEECH_FINAL__:')) {
        if (_processingTurn) return;

        final text = event.substring('__SPEECH_FINAL__:'.length).trim();
        if (text.isEmpty) return;

        _lastHeardTranscript = text;
        _setState(
          state.value.copyWith(
            transcript: text,
            voiceState: VoiceState.thinking,
            statusText: 'Thinking...',
          ),
        );

        await _runLlmAndSpeak(text);
        return;
      }

      if (event == '__UTTERANCE_END__') {
        if (_processingTurn) return;
        final text = _lastHeardTranscript.trim();
        if (text.isEmpty) return;

        _setState(
          state.value.copyWith(
            voiceState: VoiceState.thinking,
            statusText: 'Thinking...',
          ),
        );

        await _runLlmAndSpeak(text);
        return;
      }

      if (!event.startsWith('__')) {
        final clean = event.startsWith('[')
            ? event.substring(1, event.length - 1)
            : event;
        if (clean.isNotEmpty) _lastHeardTranscript = clean;

        if (_processingTurn) return;
        _setState(state.value.copyWith(transcript: clean));
      }
    });
  }

  Future<void> toggleSession() async {
    if (kIsWeb) {
      _setState(
        state.value.copyWith(
          voiceState: VoiceState.error,
          statusText: 'Voice requires the native app.',
        ),
      );
      return;
    }
    if (state.value.voiceState == VoiceState.idle ||
        state.value.voiceState == VoiceState.error) {
      await startSession();
    } else {
      await stopSession();
    }
  }

  Future<void> startSession() async {
    _setState(
      state.value.copyWith(
        voiceState: VoiceState.listening,
        statusText: 'Listening...',
        transcript: '',
        lastResponse: '',
        clearError: true,
      ),
    );
    _lastHeardTranscript = '';
    _processingTurn = false;

    try {
      await _stt.start();
    } catch (e) {
      final err = classifyError(e);
      _setState(
        state.value.copyWith(
          voiceState: VoiceState.error,
          statusText: err.message,
          errorInfo: err,
        ),
      );
    }
  }

  Future<void> stopSession() async {
    _processingTurn = false;
    await _tts.stop();
    await _stt.stop();
    _llm.clearHistory();
    _lastHeardTranscript = '';

    _setState(
      state.value.copyWith(
        voiceState: VoiceState.idle,
        statusText: 'Tap to speak',
        transcript: '',
        clearError: true,
      ),
    );
  }

  Future<void> _runLlmAndSpeak(String userText) async {
    _processingTurn = true;
    _lastHeardTranscript = '';

    try {
      final buffer = StringBuffer();
      await for (final chunk in _llm.chat(userText)) {
        buffer.write(chunk);
      }

      final response = buffer.toString().trim();
      if (response.isEmpty) return;

      _setState(
        state.value.copyWith(
          lastResponse: response,
          voiceState: VoiceState.speaking,
          statusText: 'Speaking...',
        ),
      );

      _stt.muteMic();
      try {
        await _tts.speak(response);
      } finally {
        _stt.unmuteMic();
      }

      if (state.value.voiceState == VoiceState.speaking) {
        _setState(
          state.value.copyWith(
            voiceState: VoiceState.listening,
            statusText: 'Listening...',
            transcript: '',
          ),
        );
      }
    } catch (e) {
      final err = classifyError(e);
      if (err.fatal) {
        await _stt.stop();
        _setState(
          state.value.copyWith(
            voiceState: VoiceState.error,
            statusText: err.message,
            errorInfo: err,
          ),
        );
      } else {
        onToast?.call(err.message, isError: true);
        _setState(
          state.value.copyWith(
            voiceState: VoiceState.listening,
            statusText: 'Listening...',
          ),
        );
      }
    } finally {
      _processingTurn = false;
    }
  }

  Future<void> _handleBargeIn() async {
    final current = state.value;
    if (current.voiceState != VoiceState.speaking) return;

    _processingTurn = false;

    if (current.lastResponse.isNotEmpty) {
      _llm.updateLastAssistantMessage(
        '${current.lastResponse} [interrupted by user]',
      );
    }

    await _tts.fadeAndStop();
    _stt.bargeIn();

    _setState(
      state.value.copyWith(
        voiceState: VoiceState.listening,
        statusText: 'Listening...',
        transcript: '',
      ),
    );
  }

  void dispose() {
    _transcriptSub?.cancel();
    _stt.dispose();
    _tts.dispose();
    state.dispose();
  }
}
