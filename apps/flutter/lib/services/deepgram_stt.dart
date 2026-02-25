import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'settings_service.dart';
import 'stt_events.dart';
import 'voice_ports.dart';

enum SttState { idle, connecting, listening, reconnecting, error }

class DeepgramStt implements SttService {
  WebSocket? _ws;
  WebSocketChannel? _channel;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSub;
  Timer? _reconnectTimer;
  Timer? _healthTimer;

  final _eventController = StreamController<SttEvent>.broadcast();
  final _stateController = StreamController<SttState>.broadcast();
  final List<String> _finalBuffer = [];

  @override
  Stream<SttEvent> get events => _eventController.stream;
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

  void _emitEvent(SttEvent event) {
    if (!_disposed && !_eventController.isClosed) {
      _eventController.add(event);
    }
  }

  void _setState(SttState s) {
    _state = s;
    if (!_disposed && !_stateController.isClosed) {
      _stateController.add(s);
    }
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  @override
  Future<void> start() async {
    if (_sessionActive) return;
    _sessionActive = true;
    _reconnectAttempts = 0;
    _isReconnecting = false;
    _finalBuffer.clear();
    await _connect();
  }

  @override
  void muteMic() {
    _micMuted = true;
    _suppressUntil = null;
    _muteStart = DateTime.now(); // record when TTS began for timing gate
    _finalBuffer.clear();
  }

  @override
  void unmuteMic() {
    // If bargeIn() was already called, _micMuted is already false.
    // Don't re-apply the grace period — that would suppress the user's barge-in
    // speech that Deepgram is about to deliver.
    if (!_micMuted) return;
    _micMuted = false;
    _muteStart = null;

    // Desktop leaks a much longer tail of speaker audio (no reliable hardware
    // AEC in unsigned debug builds). Use a stronger quarantine window there.
    // Mobile keeps the shorter window for responsiveness.
    final graceMs = (Platform.isMacOS || Platform.isWindows) ? 4500 : 800;
    _suppressUntil = DateTime.now().add(Duration(milliseconds: graceMs));
    _finalBuffer.clear();
  }

  /// Called on barge-in: skip the grace period and immediately accept speech.
  /// Audio was always flowing to Deepgram — it has the user's words buffered.
  @override
  void bargeIn() {
    _micMuted = false;
    _suppressUntil = null;
    _muteStart = null;
    _finalBuffer.clear();
  }

  @override
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

  @override
  void dispose() {
    _disposed = true;
    _healthTimer?.cancel();
    _reconnectTimer?.cancel();
    stop();
    _eventController.close();
    _stateController.close();
  }

  // ── Connection ─────────────────────────────────────────────────────────────

  Future<void> _connect() async {
    if (!_sessionActive || _disposed) return;

    _setState(SttState.connecting);
    try {
      final s = SettingsService.instance;
      final ws =
          await WebSocket.connect(
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
        _emitEvent(const SttReconnected());
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

    // echoCancel/autoGain on macOS calls setVoiceProcessingEnabled which fails
    // in an unsigned sandbox build. Enable only on mobile platforms where the
    // OS audio session handles it cleanly. macOS echo is handled by the 700ms
    // timing gate on SpeechStarted instead.
    final bool usePlatformAec = !Platform.isMacOS && !Platform.isWindows;

    final stream = await _recorder!.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        echoCancel: usePlatformAec,
        noiseSuppress: usePlatformAec,
        autoGain: usePlatformAec,
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

  // Maximum reconnect attempts before surfacing a fatal error.
  // Backoff: 1s + 2s + 4s + 8s + 16s = 31s total wait before giving up.
  static const int kMaxReconnectAttempts = 5;

  void _scheduleReconnect() {
    if (_isReconnecting || !_sessionActive || _disposed) return;

    // Give up after kMaxReconnectAttempts and surface a typed fatal event so
    // voice UI can show actionable recovery instead of spinning forever.
    if (_reconnectAttempts >= kMaxReconnectAttempts) {
      _sessionActive = false;
      _setState(SttState.error);
      _emitEvent(const SttFailed());
      return;
    }

    _isReconnecting = true;
    _setState(SttState.reconnecting);
    _emitEvent(const SttReconnecting());

    // Exponential backoff: 1s, 2s, 4s, 8s, 16s — then gives up
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
      //
      // Barge-in via SpeechStarted is ONLY reliable when hardware AEC is
      // active (iOS/Android). On macOS/Windows the mic picks up speaker echo
      // throughout TTS — echo fires SpeechStarted after the timing gate,
      // clears suppression, then echo transcripts loop back as user input.
      // On desktop platforms we simply let TTS finish; barge-in is enabled
      // on mobile once hardware AEC removes the echo signal entirely.
      if (type == 'SpeechStarted') {
        final bargeInSupported = !Platform.isMacOS && !Platform.isWindows;
        if (bargeInSupported && _micMuted) {
          final start = _muteStart;
          final elapsed = start != null
              ? DateTime.now().difference(start).inMilliseconds
              : 9999;
          if (elapsed > 700) {
            _emitEvent(const SttSpeechStarted());
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
          _emitEvent(SttTranscriptPartial(transcript));
        }

        if (isFinal && transcript.isNotEmpty) {
          _finalBuffer.add(transcript);
          _emitEvent(SttTranscriptFinal(transcript));
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
      _emitEvent(SttSpeechFinal(full));
    }
  }
}
