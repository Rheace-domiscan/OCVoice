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
    _finalBuffer.clear();
  }

  void unmuteMic() {
    _micMuted = false;
    // 800ms grace: ignore any Deepgram frames still in flight from TTS echo
    _suppressUntil = DateTime.now().add(const Duration(milliseconds: 800));
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

      // Dart sends WS ping every 5s; no pong → socket closed → _onWsDone fires.
      // This is the primary fast-drop-detection mechanism.
      ws.pingInterval = const Duration(seconds: 5);

      _ws = ws;
      _channel = IOWebSocketChannel(ws);
      _channel!.stream.listen(
        _onMessage,
        onError: _onWsError,
        onDone: _onWsDone,
      );

      await _startMic();
      _reconnectAttempts = 0; // reset backoff on success
      _startHealthCheck();
      _setState(SttState.listening);

      if (_isReconnecting) {
        _isReconnecting = false;
        _emit('__RECONNECTED__');
      }
    } catch (e) {
      if (_sessionActive && !_disposed) {
        // ⚠️ Critical: reset _isReconnecting so _scheduleReconnect() isn't
        // blocked by its own guard on the next retry attempt.
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
      ),
    );

    _audioSub = stream.listen((chunk) {
      // Audio always flows to Deepgram (keeps WS alive).
      // _isSuppressed only controls whether transcripts trigger turns.
      final ch = _channel;
      if (ch == null) return;
      try {
        ch.sink.add(chunk);
      } catch (_) {
        // Sink threw — connection dead; trigger reconnect immediately
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

  // ── Health check (belt-and-suspenders for dead readyState) ────────────────

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
    // One reconnect cycle at a time; _isReconnecting is reset in _connect()
    // catch block before calling here so retries aren't self-blocked.
    if (_isReconnecting || !_sessionActive || _disposed) return;

    _isReconnecting = true;
    _setState(SttState.reconnecting);
    _emit('__RECONNECTING__');

    // Exponential backoff: 1s, 2s, 4s, 8s … capped at 30s
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

      if (type == 'Results') {
        final ch = (json['channel'] as Map<String, dynamic>?);
        final alternatives = ch?['alternatives'] as List<dynamic>?;
        final transcript =
            alternatives?.firstOrNull?['transcript'] as String? ?? '';
        final isFinal = json['is_final'] as bool? ?? false;
        final speechFinal = json['speech_final'] as bool? ?? false;

        // Drop ALL transcript events when mic is suppressed (muted or grace
        // period). This prevents TTS echo from entering the turn pipeline.
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
