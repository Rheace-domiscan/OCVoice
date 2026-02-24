import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/deepgram_stt.dart';
import '../services/openclaw_client.dart';
import '../services/elevenlabs_tts.dart';
import 'onboarding_screen.dart';

// ── Palette (matches onboarding) ──────────────────────────────────────────────
const _kBg = Color(0xFF090E1A);
const _kSurface = Color(0xFF111827);
const _kBorder = Color(0xFF1F2937);
const _kGold = Color(0xFFC9A96E);
const _kBlue = Color(0xFF60A5FA);
const _kGreen = Color(0xFF4ADE80);
const _kRed = Color(0xFFF87171);
const _kTextPrimary = Color(0xFFF1F5F9);
const _kTextSecondary = Color(0xFF94A3B8);
const _kTextMuted = Color(0xFF64748B);
const _kTextDim = Color(0xFF475569);

// ─────────────────────────────────────────────────────────────────────────────

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

  bool _processingTurn = false;

  VoiceState _voiceState = VoiceState.idle;
  String _statusText = 'Tap to speak';
  String _transcript = '';
  String _lastResponse = '';
  String _lastHeardTranscript = '';

  StreamSubscription<String>? _transcriptSub;

  // Pulse animation (idle → subtle, listening → medium, speaking → faster)
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // Spin animation for thinking state
  late AnimationController _spinCtrl;

  // Wave bars for listening state
  late AnimationController _waveCtrl;
  late List<Animation<double>> _waveAnims;

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.94, end: 1.06).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    // Stagger 4 wave bars
    _waveAnims = List.generate(4, (i) {
      final start = i * 0.15;
      return Tween<double>(begin: 0.2, end: 1.0).animate(
        CurvedAnimation(
          parent: _waveCtrl,
          curve: Interval(start, (start + 0.7).clamp(0.0, 1.0),
              curve: Curves.easeInOut),
        ),
      );
    });

    _listenToStt();
  }

  void _listenToStt() {
    _transcriptSub = _stt.transcripts.listen((event) async {
      // ── Reconnection events ────────────────────────────────────────────
      if (event == '__RECONNECTING__') {
        if (mounted && _voiceState != VoiceState.idle) {
          setState(() => _statusText = 'Reconnecting...');
        }
        return;
      }

      if (event == '__RECONNECTED__') {
        if (mounted && _voiceState != VoiceState.idle) {
          setState(() => _statusText = 'Listening...');
        }
        return;
      }

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
        _spinCtrl.repeat();

        await _runLlmAndSpeak(text);
        return;
      }

      if (event == '__UTTERANCE_END__') {
        if (_processingTurn) return;
        final text = _lastHeardTranscript.trim();
        if (text.isEmpty) return;

        setState(() {
          _voiceState = VoiceState.thinking;
          _statusText = 'Thinking...';
        });
        _spinCtrl.repeat();

        await _runLlmAndSpeak(text);
        return;
      }

      if (!event.startsWith('__')) {
        final clean = event.startsWith('[')
            ? event.substring(1, event.length - 1)
            : event;
        if (clean.isNotEmpty) _lastHeardTranscript = clean;

        // Barge-in: only when mic is not muted (i.e., not echo)
        if (_voiceState == VoiceState.speaking &&
            clean.isNotEmpty &&
            !_stt.isMicMuted) {
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
      final buffer = StringBuffer();
      await for (final chunk in _llm.chat(userText)) {
        buffer.write(chunk);
      }

      final response = buffer.toString().trim();
      if (response.isEmpty) return;

      if (mounted) {
        _spinCtrl.stop();
        setState(() {
          _lastResponse = response;
          _voiceState = VoiceState.speaking;
          _statusText = 'Speaking...';
        });
      }

      _stt.muteMic();
      try {
        await _tts.speak(response);
      } finally {
        _stt.unmuteMic();
      }

      if (mounted) {
        setState(() {
          _voiceState = VoiceState.listening;
          _statusText = 'Listening...';
          _transcript = '';
        });
      }
    } catch (e) {
      _spinCtrl.stop();
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
        _statusText = 'Voice requires the native app.';
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
    _spinCtrl.stop();
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

  // ── State-derived values ──────────────────────────────────────────────────

  Color get _stateColor => switch (_voiceState) {
        VoiceState.idle => _kBorder,
        VoiceState.listening => _kGold,
        VoiceState.thinking => _kGold,
        VoiceState.speaking => _kBlue,
        VoiceState.error => _kRed,
      };

  IconData get _stateIcon => switch (_voiceState) {
        VoiceState.idle || VoiceState.error => Icons.mic_none_rounded,
        VoiceState.listening => Icons.mic_rounded,
        VoiceState.thinking => Icons.mic_rounded,
        VoiceState.speaking => Icons.volume_up_rounded,
      };

  bool get _isPulsing =>
      _voiceState == VoiceState.listening ||
      _voiceState == VoiceState.speaking;

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            const Spacer(flex: 2),
            _buildTranscript(),
            const SizedBox(height: 48),
            _buildMicButton(),
            const SizedBox(height: 32),
            _buildStatusLabel(),
            const Spacer(flex: 3),
            _buildResponseText(),
          ],
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'O C V o i c e',
            style: TextStyle(
              color: _kTextMuted,
              fontSize: 13,
              letterSpacing: 4,
              fontWeight: FontWeight.w300,
            ),
          ),
          IconButton(
            onPressed: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (_) => const OnboardingScreen(),
                ),
              );
            },
            icon: const Icon(Icons.tune_rounded, size: 20, color: _kTextDim),
            tooltip: 'Settings',
          ),
        ],
      ),
    );
  }

  // ── Transcript ────────────────────────────────────────────────────────────

  Widget _buildTranscript() {
    if (_transcript.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Text(
        _transcript,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: _kTextSecondary,
          fontSize: 16,
          height: 1.6,
          fontWeight: FontWeight.w300,
        ),
      ),
    );
  }

  // ── Mic button ────────────────────────────────────────────────────────────

  Widget _buildMicButton() {
    return GestureDetector(
      onTap: _toggleSession,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulseAnim, _spinCtrl]),
        builder: (context, child) {
          final scale = _isPulsing ? _pulseAnim.value : 1.0;

          return Transform.scale(
            scale: scale,
            child: SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Outer glow
                  if (_voiceState != VoiceState.idle)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _stateColor.withOpacity(0.18),
                            blurRadius: 40,
                            spreadRadius: 12,
                          ),
                        ],
                      ),
                    ),

                  // Spinning arc for thinking state
                  if (_voiceState == VoiceState.thinking)
                    RotationTransition(
                      turns: _spinCtrl,
                      child: CustomPaint(
                        size: const Size(130, 130),
                        painter: _ArcPainter(color: _kGold),
                      ),
                    ),

                  // Main circle
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _kSurface,
                      border: Border.all(
                        color: _stateColor,
                        width: _voiceState == VoiceState.idle ? 1 : 1.5,
                      ),
                    ),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: _voiceState == VoiceState.listening
                            ? _WaveBars(anims: _waveAnims, color: _kGold)
                            : Icon(
                                _stateIcon,
                                key: ValueKey(_voiceState),
                                color: _voiceState == VoiceState.idle
                                    ? _kTextDim
                                    : _stateColor,
                                size: 36,
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Status label ──────────────────────────────────────────────────────────

  Widget _buildStatusLabel() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Text(
        _statusText,
        key: ValueKey(_statusText),
        textAlign: TextAlign.center,
        style: TextStyle(
          color: _voiceState == VoiceState.error ? _kRed : _kTextMuted,
          fontSize: 13,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }

  // ── Response text ─────────────────────────────────────────────────────────

  Widget _buildResponseText() {
    if (_lastResponse.isEmpty) return const SizedBox(height: 44);
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 36, 44),
      child: Text(
        _lastResponse,
        textAlign: TextAlign.center,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: _kTextDim,
          fontSize: 13,
          height: 1.7,
          fontWeight: FontWeight.w300,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _transcriptSub?.cancel();
    _pulseCtrl.dispose();
    _spinCtrl.dispose();
    _waveCtrl.dispose();
    _stt.dispose();
    _tts.dispose();
    super.dispose();
  }
}

// ── Wave bars widget ──────────────────────────────────────────────────────────

class _WaveBars extends StatelessWidget {
  const _WaveBars({required this.anims, required this.color});

  final List<Animation<double>> anims;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anims.first,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(anims.length, (i) {
            final height = 10.0 + (anims[i].value * 22.0);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 3.5,
              height: height,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}

// ── Spinning arc painter (thinking state) ────────────────────────────────────

class _ArcPainter extends CustomPainter {
  const _ArcPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withOpacity(0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawArc(rect, 0, math.pi * 1.3, false, paint);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}
