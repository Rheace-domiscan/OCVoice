import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'settings_service.dart';
import 'voice_ports.dart';

class ElevenLabsTts implements TtsService {
  AudioPlayer? _player;
  bool _isSpeaking = false;

  bool get isSpeaking => _isSpeaking;

  Stream<bool> get speakingStream =>
      _player?.playingStream ?? const Stream<bool>.empty();

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    _isSpeaking = true;

    try {
      final bytes = await _fetchAudio(text);
      await _resetPlayer();
      final player = _player!;
      await _playBytes(player, bytes);
    } finally {
      _isSpeaking = false;
    }
  }

  @override
  Future<void> stop() async {
    final p = _player;
    if (p == null) {
      _isSpeaking = false;
      return;
    }
    try {
      await p.stop();
    } on PlatformException catch (e) {
      if (!_isIosAudioSessionError(e)) rethrow;
    }
    _isSpeaking = false;
  }

  @override
  Future<void> fadeAndStop() async {
    final p = _player;
    if (!_isSpeaking || p == null) return;
    try {
      for (var v = 0.8; v >= 0; v -= 0.2) {
        await p.setVolume(v < 0 ? 0 : v);
        await Future.delayed(const Duration(milliseconds: 25));
      }
    } catch (_) {}
    try {
      await p.stop();
      await p.setVolume(1.0);
    } on PlatformException catch (e) {
      if (!_isIosAudioSessionError(e)) rethrow;
    }
    _isSpeaking = false;
  }

  Future<Uint8List> _fetchAudio(String text) async {
    final s = SettingsService.instance;
    final response = await http.post(
      Uri.parse(s.ttsUrl),
      headers: {
        'xi-api-key': s.elevenLabsKey,
        'Content-Type': 'application/json',
        'Accept': 'audio/mpeg',
      },
      body:
          '''
{
  "text": ${_jsonString(text)},
  "model_id": "eleven_turbo_v2_5",
  "voice_settings": {
    "stability": 0.5,
    "similarity_boost": 0.75,
    "style": 0.0,
    "use_speaker_boost": true
  },
  "output_format": "mp3_44100_128"
}''',
    );

    if (response.statusCode != 200) {
      throw Exception(
        'ElevenLabs TTS error: ${response.statusCode} ${response.body}',
      );
    }

    return response.bodyBytes;
  }

  Future<void> _playBytes(AudioPlayer initialPlayer, Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final outDir = Directory(dir.path);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final file = File(
      '${outDir.path}/ocvoice_tts_${DateTime.now().millisecondsSinceEpoch}.mp3',
    );
    await file.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);

    var player = initialPlayer;

    Future<void> playOnce() async {
      await player.setFilePath(file.path);
      final completion = player.processingStateStream.firstWhere(
        (s) => s == ProcessingState.completed || s == ProcessingState.idle,
      );
      await player.play();
      await completion;
    }

    try {
      await playOnce();
    } on PlatformException catch (e) {
      if (_isIosAudioSessionError(e)) {
        // One hard reset+retry per utterance.
        await _resetPlayer();
        player = _player!;
        await playOnce();
      } else {
        rethrow;
      }
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  String _jsonString(String s) {
    return '"${s.replaceAll(r'\\', r'\\\\').replaceAll('"', r'\\"').replaceAll('\n', r'\\n')}"';
  }

  bool _isIosAudioSessionError(PlatformException e) {
    final code = e.code.toString();
    final msg = (e.message ?? '').toLowerCase();
    return code == '561017449' || msg.contains('osstatus error 561017449');
  }

  Future<void> _resetPlayer() async {
    final old = _player;
    _player = AudioPlayer();
    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _player?.dispose();
  }
}
