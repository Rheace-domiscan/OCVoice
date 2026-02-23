import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'settings_service.dart';

enum SttState { idle, connecting, listening, error }

class DeepgramStt {
  WebSocketChannel? _channel;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSub;

  final _transcriptController = StreamController<String>.broadcast();
  final _stateController = StreamController<SttState>.broadcast();

  // Accumulates is_final transcript segments between utterance boundaries
  final List<String> _finalBuffer = [];

  Stream<String> get transcripts => _transcriptController.stream;
  Stream<SttState> get states => _stateController.stream;

  SttState _state = SttState.idle;
  SttState get state => _state;

  void _setState(SttState s) {
    _state = s;
    _stateController.add(s);
  }

  Future<void> start() async {
    if (_state != SttState.idle) return;
    _finalBuffer.clear();
    _setState(SttState.connecting);

    try {
      // Native: use dart:io WebSocket with Authorization header
      final s = SettingsService.instance;
      final ws = await WebSocket.connect(
        s.deepgramWsUrl,
        headers: {
          'Authorization': 'Token ${s.deepgramKey}',
        },
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Deepgram connection timed out'),
      );

      _channel = IOWebSocketChannel(ws);

      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );

      await _startMic();
      _setState(SttState.listening);
    } catch (e) {
      _setState(SttState.error);
      rethrow;
    }
  }

  // When true, barge-in is suppressed (used during TTS to ignore echo).
  // Audio still flows to Deepgram so the WebSocket connection stays alive.
  bool _micMuted = false;
  bool get isMicMuted => _micMuted;

  /// Suppress barge-in — audio still reaches Deepgram but echo-triggered
  /// interrupts are ignored. Call before TTS playback.
  void muteMic() {
    _micMuted = true;
    _finalBuffer.clear(); // discard partials accumulated before mute
  }

  /// Re-enable barge-in. Call after TTS finishes.
  void unmuteMic() {
    _micMuted = false;
    _finalBuffer.clear(); // discard any echo transcripts that slipped through
  }

  Future<void> _startMic() async {
    _recorder = AudioRecorder();
    final hasPermission = await _recorder!.hasPermission();
    if (!hasPermission) throw Exception('Microphone permission denied');

    final stream = await _recorder!.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );

    _audioSub = stream.listen((chunk) {
      // Always send audio to Deepgram — keeps the WebSocket alive even during
      // TTS playback. The _micMuted flag only controls barge-in suppression.
      _channel?.sink.add(chunk);
    });
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'Results') {
        final channel = (json['channel'] as Map<String, dynamic>?);
        final alternatives = channel?['alternatives'] as List<dynamic>?;
        final transcript =
            alternatives?.firstOrNull?['transcript'] as String? ?? '';
        final isFinal = json['is_final'] as bool? ?? false;
        final speechFinal = json['speech_final'] as bool? ?? false;

        // Show partial results in UI (prefixed with [ so UI can display them)
        if (transcript.isNotEmpty && !isFinal) {
          _transcriptController.add('[$transcript]');
        }

        // Accumulate finalised transcript segments
        if (isFinal && transcript.isNotEmpty) {
          _finalBuffer.add(transcript);
          _transcriptController.add(transcript);
        }

        // speech_final=true with content: fire the turn immediately
        if (speechFinal && transcript.isNotEmpty) {
          _fireTurn();
        }
      }

      // UtteranceEnd = definitive silence — fire whatever we've accumulated
      if (type == 'UtteranceEnd') {
        _fireTurn();
      }
    } catch (_) {}
  }

  void _fireTurn() {
    if (_micMuted) {
      // Discard echo — don't fire a turn during TTS playback
      _finalBuffer.clear();
      return;
    }
    final full = _finalBuffer.join(' ').trim();
    _finalBuffer.clear();
    if (full.isNotEmpty) {
      _transcriptController.add('__SPEECH_FINAL__:$full');
    }
  }

  void _onError(dynamic error) {
    _setState(SttState.error);
  }

  void _onDone() {
    if (_state == SttState.listening) {
      _setState(SttState.idle);
    }
  }

  Future<void> stop() async {
    _micMuted = false;
    await _audioSub?.cancel();
    await _recorder?.stop();
    _recorder?.dispose();
    _recorder = null;
    _audioSub = null;
    _finalBuffer.clear();

    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    _setState(SttState.idle);
  }

  void dispose() {
    stop();
    _transcriptController.close();
    _stateController.close();
  }
}
