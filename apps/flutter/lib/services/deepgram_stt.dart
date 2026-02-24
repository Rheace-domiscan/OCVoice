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
  WebSocket? _ws;           // raw socket — used for readyState health checks
  WebSocketChannel? _channel;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSub;
  Timer? _reconnectTimer;
  Timer? _healthTimer;       // polls socket state every 2s as belt-and-suspenders

  final _transcriptController = StreamController<String>.broadcast();
  final _stateController = StreamController<SttState>.broadcast();
  final List<String> _finalBuffer = [];

  Stream<String> get transcripts => _transcriptController.stream;
  Stream<SttState> get states => _stateController.stream;

  SttState _state = SttState.idle;
  SttState get state => _state;

  // true from start() until stop() — distinguishes intentional stop from drop
  bool _sessionActive = false;
  bool _disposed = false;

  // Reconnection state: guarded by _isReconnecting to prevent duplicate calls
  int _reconnectAttempts = 0;
  bool _isReconnecting = false;

  // Barge-in suppression (muted during TTS to avoid echo)
  bool _micMuted = false;
  bool get isMicMuted => _micMuted;

  // ── Safe emit helpers ─────────────────────────────────────────────────────

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

  // ── Public API ────────────────────────────────────────────────────────────

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
    _finalBuffer.clear();
  }

  void unmuteMic() {
    _micMuted = false;
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

  // ── Connection ────────────────────────────────────────────────────────────

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

      // pingInterval: Dart sends a WS ping every 5s.
      // If the server doesn't respond with a pong, the socket is closed and
      // _onWsDone fires — fast drop detection without relying on health poll.
      ws.pingInterval = const Duration(seconds: 5);

      _ws = ws;
      _channel = IOWebSocketChannel(ws);
      _channel!.stream.listen(
        _onMessage,
        onError: _onWsError,
        onDone: _onWsDone,
      );

      await _startMic();
      _reconnectAttempts = 0; // successful connection — reset backoff
      _startHealthCheck();
      _setState(SttState.listening);

      // If this was a reconnect (not the initial start), notify listeners
      if (_isReconnecting) {
        _isReconnecting = false;
        _emit('__RECONNECTED__');
      }
    } catch (e) {
      if (_sessionActive && !_disposed) {
        _scheduleReconnect();
      } else {
        _setState(SttState.error);
      }
    }
  }

  // ── Mic ───────────────────────────────────────────────────────────────────

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
      // _micMuted only suppresses barge-in, not the stream itself.
      // If the sink is dead and throws, treat it as a drop.
      final ch = _channel;
      if (ch == null) return;
      try {
        ch.sink.add(chunk);
      } catch (_) {
        // Sink threw — connection is dead. Trigger reconnect immediately.
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

  // ── Health check (belt-and-suspenders for readyState) ────────────────────

  void _startHealthCheck() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_sessionActive || _disposed) {
        _healthTimer?.cancel();
        return;
      }
      // readyState 1 = OPEN. Anything else = dropped/closing/closed.
      // pingInterval catches most drops faster, but this catches edge cases
      // where readyState has gone stale without firing onDone.
      if (_ws != null && _ws!.readyState != WebSocket.open) {
        _healthTimer?.cancel();
        _scheduleReconnect();
      }
    });
  }

  // ── Reconnection ──────────────────────────────────────────────────────────

  void _scheduleReconnect() {
    // Guard: only one reconnect cycle at a time
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

  // ── WebSocket callbacks ───────────────────────────────────────────────────

  void _onWsError(dynamic error) {
    if (_sessionActive && !_disposed) {
      _scheduleReconnect();
    }
  }

  void _onWsDone() {
    _channel = null;
    _ws = null;
    if (_sessionActive && !_disposed) {
      // Unexpected close — reconnect
      _scheduleReconnect();
    }
  }

  // ── Message parsing ───────────────────────────────────────────────────────

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
        _fireTurn();
      }
    } catch (_) {}
  }

  void _fireTurn() {
    if (_micMuted) {
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
