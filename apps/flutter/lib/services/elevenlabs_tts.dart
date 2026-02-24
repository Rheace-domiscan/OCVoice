import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'settings_service.dart';

class ElevenLabsTts {
  final AudioPlayer _player = AudioPlayer();
  bool _isSpeaking = false;

  bool get isSpeaking => _isSpeaking;

  Stream<bool> get speakingStream => _player.playingStream;

  /// Speak the given text using ElevenLabs streaming TTS.
  /// Returns when playback is complete.
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    _isSpeaking = true;

    try {
      final bytes = await _fetchAudio(text);
      await _playBytes(bytes);
    } finally {
      _isSpeaking = false;
    }
  }

  /// Stop any current playback immediately (hard stop).
  Future<void> stop() async {
    await _player.stop();
    await _player.setVolume(1.0); // reset for next play
    _isSpeaking = false;
  }

  /// Graceful stop: fade volume to 0 over ~150ms then stop.
  /// Used on barge-in so the cut feels like being heard, not cut off.
  Future<void> fadeAndStop() async {
    if (!_isSpeaking) return;
    try {
      // 6 steps × 25ms = 150ms total fade
      for (var v = 0.8; v >= 0; v -= 0.2) {
        await _player.setVolume(v < 0 ? 0 : v);
        await Future.delayed(const Duration(milliseconds: 25));
      }
    } catch (_) {}
    await _player.stop();
    await _player.setVolume(1.0); // reset for next play
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
      body: '''
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

  Future<void> _playBytes(Uint8List bytes) async {
    // Write to temp file and play
    final dir = await getTemporaryDirectory();

    // Ensure cache/temp directory exists in sandboxed macOS app container
    final outDir = Directory(dir.path);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final file = File(
      '${outDir.path}/ocvoice_tts_${DateTime.now().millisecondsSinceEpoch}.mp3',
    );

    await file.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);

    await _player.setFilePath(file.path);
    // Subscribe BEFORE play() to avoid race condition on short audio.
    // Also accept idle: when stopped externally (e.g. barge-in fadeAndStop),
    // just_audio transitions to idle not completed — without this the future
    // would hang forever and block the voice turn pipeline.
    final completion = _player.processingStateStream.firstWhere(
      (s) => s == ProcessingState.completed || s == ProcessingState.idle,
    );
    await _player.play();
    await completion;

    // Clean up temp file
    try {
      await file.delete();
    } catch (_) {}
  }

  /// Safely JSON-encode a string value.
  String _jsonString(String s) {
    return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
  }

  void dispose() {
    _player.dispose();
  }
}
