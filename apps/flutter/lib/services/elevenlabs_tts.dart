import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';

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

  /// Stop any current playback immediately.
  Future<void> stop() async {
    await _player.stop();
    _isSpeaking = false;
  }

  Future<Uint8List> _fetchAudio(String text) async {
    final response = await http.post(
      Uri.parse(AppConfig.elevenLabsTtsUrl),
      headers: {
        'xi-api-key': AppConfig.elevenLabsApiKey,
        'Content-Type': 'application/json',
        'Accept': 'audio/mpeg',
      },
      body: '''
{
  "text": ${_jsonString(text)},
  "model_id": "${AppConfig.elevenLabsModel}",
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
    await _player.play();
    await _player.processingStateStream.firstWhere(
      (s) => s == ProcessingState.completed,
    );

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
