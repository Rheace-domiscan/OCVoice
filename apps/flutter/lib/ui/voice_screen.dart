import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/deepgram_stt.dart';
import '../services/openclaw_client.dart';
import '../services/elevenlabs_tts.dart';

enum VoiceState { idle, listening, thinking, speaking, error }

class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen>
    with TickerProviderStateMixin {
  final _stt = DeepgramStt();
  final _llm = OpenClawClient();
  final _tts = ElevenLabsTts();

  // Single guard — are we mid-LLM+TTS turn?
  bool _processingTurn = false;

  VoiceState _voiceState = VoiceState.idle;
  String _statusText = 'Tap to speak';
  String _transcript = '';
  String _lastResponse = '';
  String _lastHeardTranscript = '';

  StreamSubscription<String>? _transcriptSub;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.9, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _listenToStt();
  }

  void _listenToStt() {
    _transcriptSub = _stt.transcripts.listen((event) async {
      if (event.startsWith('__SPEECH_FINAL__:')) {
        if (_processingTurn) return;

        final text = event.substring('__SPEECH_FINAL__:'.length).trim();
        if (text.isEmpty) return;

        _lastHeardTranscript = text;
        setState(() {
          _transcript = text;
          _voiceState = VoiceState.thinking;
          _statusText = 'Thinking...';
        });

        await _runLlmAndSpeak(text);
        return;
      }

      if (event == '__UTTERANCE_END__') {
        // Fallback path when speech_final is delayed/missing.
        if (_processingTurn) return;
        final text = _lastHeardTranscript.trim();
        if (text.isEmpty) return;

        setState(() {
          _voiceState = VoiceState.thinking;
          _statusText = 'Thinking...';
        });

        await _runLlmAndSpeak(text);
        return;
      }

      if (!event.startsWith('__')) {
        final clean = event.startsWith('[')
            ? event.substring(1, event.length - 1)
            : event;
        if (clean.isNotEmpty) {
          _lastHeardTranscript = clean;
        }

        // Automatic interruption (barge-in): user speaks while assistant is talking.
        if (_voiceState == VoiceState.speaking && clean.isNotEmpty) {
          await _tts.stop();
          if (mounted) {
            setState(() {
              _voiceState = VoiceState.listening;
              _statusText = 'Listening...';
            });
          }
        }

        if (_processingTurn) return;
        if (mounted) setState(() => _transcript = clean);
      }
    });
  }

  Future<void> _runLlmAndSpeak(String userText) async {
    _processingTurn = true;
    _lastHeardTranscript = '';

    try {
      // Buffer full LLM response (streaming)
      final buffer = StringBuffer();
      await for (final chunk in _llm.chat(userText)) {
        buffer.write(chunk);
      }

      final response = buffer.toString().trim();
      if (response.isEmpty) return;

      if (mounted) {
        setState(() {
          _lastResponse = response;
          _voiceState = VoiceState.speaking;
          _statusText = 'Speaking...';
        });
      }

      // Play TTS — mic stays open but _processingTurn blocks overlapping finals
      await _tts.speak(response);

      // Back to listening (mic already running)
      if (mounted && _stt.state == SttState.listening) {
        setState(() {
          _voiceState = VoiceState.listening;
          _statusText = 'Listening...';
          _transcript = '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _voiceState = VoiceState.error;
          _statusText = 'Error: $e';
        });
      }
    } finally {
      _processingTurn = false;
    }
  }

  Future<void> _toggleSession() async {
    if (kIsWeb) {
      setState(() {
        _voiceState = VoiceState.error;
        _statusText = 'Voice not supported in browser.\nInstall the native app.';
      });
      return;
    }

    if (_voiceState == VoiceState.idle || _voiceState == VoiceState.error) {
      await _startSession();
    } else {
      await _stopSession();
    }
  }

  Future<void> _startSession() async {
    setState(() {
      _voiceState = VoiceState.listening;
      _statusText = 'Listening...';
      _transcript = '';
      _lastResponse = '';
      _lastHeardTranscript = '';
      _processingTurn = false;
    });

    try {
      await _stt.start();
    } catch (e) {
      setState(() {
        _voiceState = VoiceState.error;
        _statusText = 'Mic error: $e';
      });
    }
  }

  Future<void> _stopSession() async {
    _processingTurn = false;
    await _tts.stop();
    await _stt.stop();
    _llm.clearHistory();
    setState(() {
      _voiceState = VoiceState.idle;
      _statusText = 'Tap to speak';
      _transcript = '';
      _lastHeardTranscript = '';
    });
  }

  Color get _stateColor {
    return switch (_voiceState) {
      VoiceState.idle => const Color(0xFF3A3A3A),
      VoiceState.listening => const Color(0xFF1DB954),
      VoiceState.thinking => const Color(0xFFF5A623),
      VoiceState.speaking => const Color(0xFF4A90E2),
      VoiceState.error => const Color(0xFFE74C3C),
    };
  }

  bool get _isPulsing =>
      _voiceState == VoiceState.listening ||
      _voiceState == VoiceState.speaking;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'OCVoice',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 18,
                  fontWeight: FontWeight.w300,
                  letterSpacing: 4,
                ),
              ),
            ),

            const Spacer(),

            if (_transcript.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _transcript,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
              ),

            const SizedBox(height: 40),

            GestureDetector(
              onTap: _toggleSession,
              child: AnimatedBuilder(
                animation: _pulseAnim,
                builder: (context, child) {
                  final scale = _isPulsing ? _pulseAnim.value : 1.0;
                  return Transform.scale(scale: scale, child: child);
                },
                child: Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _stateColor,
                    boxShadow: [
                      BoxShadow(
                        color: _stateColor.withOpacity(0.4),
                        blurRadius: 30,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                  child: Icon(
                    _voiceState == VoiceState.idle ||
                            _voiceState == VoiceState.error
                        ? Icons.mic
                        : Icons.stop,
                    color: Colors.white,
                    size: 48,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 32),

            Text(
              _statusText,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 14,
                letterSpacing: 1,
              ),
            ),

            const Spacer(),

            if (_lastResponse.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                child: Text(
                  _lastResponse,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white24,
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _transcriptSub?.cancel();
    _pulseController.dispose();
    _stt.dispose();
    _tts.dispose();
    super.dispose();
  }
}
