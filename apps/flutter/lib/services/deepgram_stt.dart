import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';

enum SttState { idle, connecting, listening, error }

class DeepgramStt {
  WebSocketChannel? _channel;
  AudioRecorder? _recorder;
  StreamSubscription<Uint8List>? _audioSub;

  final _transcriptController = StreamController<String>.broadcast();
  final _stateController = StreamController<SttState>.broadcast();

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
    _setState(SttState.connecting);

    try {
      // Auth via query param (works on all platforms including web)
      final authedUri = Uri.parse(
        '${AppConfig.deepgramWsUrl}&token=${AppConfig.deepgramApiKey}',
      );
      _channel = WebSocketChannel.connect(authedUri);

      // Wait briefly for the connection to establish
      await _channel!.ready.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw Exception('Deepgram connection timed out'),
      );

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
      if (_channel != null) {
        _channel!.sink.add(chunk);
      }
    });
  }

  void _onMessage(dynamic data) {
    if (data is! String) return;
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      final type = json['type'] as String?;

      if (type == 'Results') {
        final channel = (json['channel'] as Map<String, dynamic>?);
        final alternatives =
            channel?['alternatives'] as List<dynamic>?;
        final transcript =
            alternatives?.firstOrNull?['transcript'] as String? ?? '';
        final isFinal = json['is_final'] as bool? ?? false;
        final speechFinal = json['speech_final'] as bool? ?? false;

        if (transcript.isNotEmpty) {
          _transcriptController.add(
            isFinal ? transcript : '[$transcript]', // prefix partial
          );
        }

        if (speechFinal && transcript.isNotEmpty) {
          // Signal that speech is done — caller uses this to trigger OpenClaw
          _transcriptController.add('__SPEECH_FINAL__:$transcript');
        }
      }

      if (type == 'UtteranceEnd') {
        _transcriptController.add('__UTTERANCE_END__');
      }
    } catch (_) {}
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
    await _audioSub?.cancel();
    await _recorder?.stop();
    _recorder?.dispose();
    _recorder = null;
    _audioSub = null;

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
