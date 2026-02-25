import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/deepgram_stt.dart';
import '../../services/elevenlabs_tts.dart';
import '../../services/openclaw_client.dart';
import '../../services/stt_events.dart';
import '../../services/voice_ports.dart';
import 'voice_error.dart';
import 'voice_models.dart';

typedef VoiceToastCallback = void Function(String message, {bool isError});

class VoiceController {
  VoiceController({
    this.onToast,
    SttService? stt,
    LlmService? llm,
    TtsService? tts,
  }) : _stt = stt ?? DeepgramStt(),
       _llm = llm ?? OpenClawClient(),
       _tts = tts ?? ElevenLabsTts() {
    _listenToStt();
  }

  final SttService _stt;
  final LlmService _llm;
  final TtsService _tts;

  final ValueNotifier<VoiceViewState> state = ValueNotifier(
    VoiceViewState.initial(),
  );

  final VoiceToastCallback? onToast;

  bool _processingTurn = false;
  StreamSubscription<SttEvent>? _sttEventSub;

  void _setState(VoiceViewState next) {
    state.value = next;
  }

  void _listenToStt() {
    _sttEventSub = _stt.events.listen((event) async {
      final current = state.value;

      switch (event) {
        case SttReconnecting():
          if (current.voiceState != VoiceState.idle) {
            _setState(
              current.copyWith(
                voiceState: VoiceState.reconnecting,
                statusText: 'Reconnecting...',
              ),
            );
          }
          return;

        case SttReconnected():
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

        case SttFailed():
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

        case SttSpeechStarted():
          if (state.value.voiceState == VoiceState.speaking) {
            await _handleBargeIn();
          }
          return;

        case SttSpeechFinal(text: final text):
          if (_processingTurn) return;
          final clean = text.trim();
          if (clean.isEmpty) return;

          _setState(
            state.value.copyWith(
              transcript: clean,
              voiceState: VoiceState.thinking,
              statusText: 'Thinking...',
            ),
          );
          await _runLlmAndSpeak(clean);
          return;

        case SttTranscriptPartial(text: final text):
          if (_processingTurn) return;
          _setState(state.value.copyWith(transcript: text));
          return;

        case SttTranscriptFinal(text: final text):
          if (_processingTurn) return;
          _setState(state.value.copyWith(transcript: text));
          return;
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
      debugPrint('VoiceController pipeline error: $e');
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
        final toastText =
            (err.message == 'Something went wrong' && err.hint != null)
            ? err.hint!
            : err.message;
        onToast?.call(toastText, isError: true);
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
    _sttEventSub?.cancel();
    _stt.dispose();
    _tts.dispose();
    state.dispose();
  }
}
