import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'settings_service.dart';

enum SttState { idle, connecting, listening, reconnecting, error }

class DeepgramStt {
  WebSocket? _ws;
  WebSocketChannel? _channel;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSub;
  Timer? _reconnectTimer;
  Timer? _healthTimer;

  final _transcriptController = StreamController<String>.broadcast();
  final _stateController = StreamController<SttState>.broadcast();
  final List<String> _finalBuffer = [];

  Stream<String> get transcripts => _transcriptController.stream;
  Stream<SttState> get states => _stateController.stream;

  SttState _state = SttState.idle;
  SttState get state => _state;

  bool _sessionActive = false;
  bool _disposed = false;

  int _reconnectAttempts = 0;
  bool _isReconnecting = false;

  // ── Echo suppression ───────────────────────────────────────────────────────
  // _micMuted is true during TTS playback.
  // _suppressUntil gives an 800ms grace window after unmute so late-arriving
  // Deepgram echo frames (still in the pipeline) don't trigger a new turn.
  bool _micMuted = false;
  bool get isMicMuted => _micMuted;
  DateTime? _suppressUntil;
  DateTime? _muteStart; // tracks when TTS started for barge-in timing gate

  bool get _isSuppressed {
    if (_micMuted) return true;
    final until = _suppressUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  // ── Safe emit helpers ──────────────────────────────────────────────────────

  void _emit(String event) {
    if (!_disposed && !_transcriptController.isClosed) {
      _transcriptController.add(event);
    }
  }

  void _setState(SttState s) {
    _state = s;
    if (!_disposed && !_stateController.isClosed) {
      _stateController.add(s);
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  Future<void> start() async {
    if (_sessionActive) return;
    _sessionActive = true;
    _reconnectAttempts = 0;
    _isReconnecting = false;
    _finalBuffer.clear();
    await _connect();
  }

  void muteMic() {
    _micMuted = true;
    _suppressUntil = null;
    _muteStart = DateTime.now(); // record when TTS began for timing gate
    _finalBuffer.clear();
  }

  void unmuteMic() {
    // If bargeIn() was already called, _micMuted is already false.
    // Don't re-apply the grace period — that would suppress the user's barge-in
    // speech that Deepgram is about to deliver.
    if (!_micMuted) return;
    _micMuted = false;
    _muteStart = null;
    // 800ms grace: ignore any Deepgram frames still in flight from TTS echo
    _suppressUntil = DateTime.now().add(const Duration(milliseconds: 800));
    _finalBuffer.clear();
  }

  /// Called on barge-in: skip the grace period and immediately accept speech.
  /// Audio was always flowing to Deepgram — it has the user's words buffered.
  void bargeIn() {
    _micMuted = false;
    _suppressUntil = null;
    _muteStart = null;
    _finalBuffer.clear();
  }

  Future<void> stop() async {
    _sessionActive = false;
    _isReconnecting = false;
    _healthTimer?.cancel();
    _healthTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _micMuted = false;
    _suppressUntil = null;
    _muteStart = null;
    await _teardownAll();
    _setState(SttState.idle);
  }

  void dispose() {
    _disposed = true;
    _healthTimer?.cancel();
    _reconnectTimer?.cancel();
    stop();
    _transcriptController.close();
    _stateController.close();
  }

  // ── Connection ─────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    if (!_sessionActive || _disposed) return;

    _setState(SttState.connecting);
    try {
      final s = SettingsService.instance;
      final ws = await WebSocket.connect(
        s.deepgramWsUrl,
        headers: {'Authorization': 'Token ${s.deepgramKey}'},
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Deepgram connection timed out'),
      );

      if (!_sessionActive || _disposed) {
        ws.close();
        return;
      }

      ws.pingInterval = const Duration(seconds: 5);

      _ws = ws;
      _channel = IOWebSocketChannel(ws);
      _channel!.stream.listen(
        _onMessage,
        onError: _onWsError,
        onDone: _onWsDone,
      );

      await _startMic();
      _reconnectAttempts = 0;
      _startHealthCheck();
      _setState(SttState.listening);

      if (_isReconnecting) {
        _isReconnecting = false;
        _emit('__RECONNECTED__');
      }
    } catch (e) {
      if (_sessionActive && !_disposed) {
        _isReconnecting = false;
        _scheduleReconnect();
      } else {
        _setState(SttState.error);
      }
    }
  }

  // ── Mic ────────────────────────────────────────────────────────────────────

  Future<void> _startMic() async {
    _recorder = AudioRecorder();
    final hasPermission = await _recorder!.hasPermission();
    if (!hasPermission) throw Exception('Microphone permission denied');

    final stream = await _recorder!.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        // echoCancel maps to hardware/OS AEC:
        //   iOS   → AVAudioSession .voiceChat mode
        //   Android → AudioManager.MODE_IN_COMMUNICATION
        //   macOS → VoiceProcessingIO audio unit
        //   Windows → WASAPI communications AEC
        //   Web   → getUserMedia { echoCancellation: true }
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ),
    );

    _audioSub = stream.listen((chunk) {
      final ch = _channel;
      if (ch == null) return;
      try {
        ch.sink.add(chunk);
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  Future<void> _teardownAll() async {
    _healthTimer?.cancel();
    _healthTimer = null;
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _recorder?.stop();
    } catch (_) {}
    _recorder?.dispose();
    _recorder = null;
    _finalBuffer.clear();

    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    _ws = null;
  }

  // ── Health check ───────────────────────────────────────────────────────────

  void _startHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_sessionActive || _disposed) {
        _healthTimer?.cancel();
        return;
      }
      if (_ws != null && _ws!.readyState != WebSocket.open) {
        _healthTimer?.cancel();
        _scheduleReconnect();
      }
    });
  }

  // ── Reconnection ───────────────────────────────────────────────────────────

  void _scheduleReconnect() {
    if (_isReconnecting || !_sessionActive || _disposed) return;

    _isReconnecting = true;
    _setState(SttState.reconnecting);
    _emit('__RECONNECTING__');

    final delaySec = math.min(30, math.pow(2, _reconnectAttempts).toInt());
    _reconnectAttempts++;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySec), () async {
      if (!_sessionActive || _disposed) return;
      await _teardownAll();
      await _connect();
    });
  }

  // ── WebSocket callbacks ────────────────────────────────────────────────────

  void _onWsError(dynamic error) {
    if (_sessionActive && !_disposed) _scheduleReconnect();
  }

  void _onWsDone() {
    _channel = null;
    _ws = null;
    if (_sessionActive && !_disposed) _scheduleReconnect();
  }

  // ── Message parsing ────────────────────────────────────────────────────────

  void _onMessage(dynamic data) {
    if (data is! String) return;
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final type = json['type'] as String?;

      // ── Barge-in detection ───────────────────────────────────────────────
      // SpeechStarted fires at the onset of speech, before any transcript.
      // Only forward as a barge-in signal if:
      //   1. Mic is muted (TTS is actively playing, not just in grace period)
      //   2. 700ms have elapsed since TTS began (timing gate filters echo that
      //      arrives immediately when speakers start playing)
      if (type == 'SpeechStarted') {
        if (_micMuted) {
          final start = _muteStart;
          final elapsed = start != null
              ? DateTime.now().difference(start).inMilliseconds
              : 9999;
          if (elapsed > 700) {
            _emit('__SPEECH_STARTED__');
          }
        }
        return;
      }

      // ── Results / UtteranceEnd ───────────────────────────────────────────
      if (type == 'Results') {
        final ch = (json['channel'] as Map<String, dynamic>?);
        final alternatives = ch?['alternatives'] as List<dynamic>?;
        final transcript =
            alternatives?.firstOrNull?['transcript'] as String? ?? '';
        final isFinal = json['is_final'] as bool? ?? false;
        final speechFinal = json['speech_final'] as bool? ?? false;

        // Drop all transcript events when suppressed (muted or grace period).
        if (_isSuppressed) {
          if (speechFinal || isFinal) _finalBuffer.clear();
          return;
        }

        if (transcript.isNotEmpty && !isFinal) {
          _emit('[$transcript]');
        }

        if (isFinal && transcript.isNotEmpty) {
          _finalBuffer.add(transcript);
          _emit(transcript);
        }

        if (speechFinal && transcript.isNotEmpty) {
          _fireTurn();
        }
      }

      if (type == 'UtteranceEnd') {
        if (!_isSuppressed) _fireTurn();
      }
    } catch (_) {}
  }

  void _fireTurn() {
    if (_isSuppressed) {
      _finalBuffer.clear();
      return;
    }
    final full = _finalBuffer.join(' ').trim();
    _finalBuffer.clear();
    if (full.isNotEmpty) {
      _emit('__SPEECH_FINAL__:$full');
    }
  }
}
