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
const _kDimGold = Color(0xFF5C4A28); // muted gold for reconnecting state

// ─────────────────────────────────────────────────────────────────────────────

// ── Error model ───────────────────────────────────────────────────────────────

class _OcError {
  final String message;      // headline
  final String? hint;        // sub-line (what to do)
  final bool needsSettings;  // show "Settings" action button
  final bool fatal;          // false = toast + keep listening; true = stop

  const _OcError({
    required this.message,
    this.hint,
    this.needsSettings = false,
    this.fatal = true,
  });
}

_OcError _classifyError(dynamic e) {
  final s = e.toString().toLowerCase();

  // Microphone
  if (s.contains('permission') || s.contains('microphone') || s.contains('audio input')) {
    return const _OcError(
      message: 'Mic access denied',
      hint: 'System Prefs → Privacy → Microphone → allow OCVoice',
      needsSettings: false,
    );
  }

  // 401 / auth — distinguish service
  if (s.contains('401') || s.contains('unauthorized') || s.contains('invalid api key')) {
    if (s.contains('openclaw') || s.contains('gateway')) {
      return const _OcError(
        message: 'Gateway token rejected (401)',
        hint: 'Update your OpenClaw token in Settings',
        needsSettings: true,
      );
    }
    if (s.contains('elevenlabs') || s.contains('tts')) {
      return const _OcError(
        message: 'ElevenLabs key rejected (401)',
        hint: 'Update your ElevenLabs key in Settings',
        needsSettings: true,
      );
    }
    return const _OcError(
      message: 'Authentication failed',
      hint: 'Check your API keys in Settings',
      needsSettings: true,
    );
  }

  // Gateway down / transient server errors
  if (s.contains('openclaw') || s.contains('gateway')) {
    if (s.contains('503') || s.contains('502') || s.contains('504') || s.contains('500')) {
      return const _OcError(
        message: 'Gateway unreachable',
        hint: 'Is OpenClaw running? Check Tailscale.',
        fatal: false, // transient — keep listening, show toast
      );
    }
    return const _OcError(
      message: 'Gateway error',
      hint: 'Check your gateway URL in Settings',
      needsSettings: true,
      fatal: false,
    );
  }

  // ElevenLabs / TTS transient
  if (s.contains('elevenlabs') || s.contains('tts error')) {
    return const _OcError(
      message: 'Speech synthesis failed',
      hint: 'ElevenLabs may be down, or quota exceeded',
      fatal: false,
    );
  }

  // STT gave up after max reconnect attempts
  if (s.contains('__stt_failed__') || (s.contains('deepgram') && s.contains('fail'))) {
    return const _OcError(
      message: 'Speech recognition unavailable',
      hint: 'Check your Deepgram key in Settings',
      needsSettings: true,
    );
  }

  // Network / socket
  if (s.contains('socket') || s.contains('network') || s.contains('timeout') ||
      s.contains('connection refused') || s.contains('connection reset')) {
    return const _OcError(
      message: 'Network error',
      hint: 'Check your connection and try again',
      fatal: false,
    );
  }

  // Unknown — show abbreviated message
  final raw = e.toString();
  return _OcError(
    message: 'Something went wrong',
    hint: raw.length <= 80 ? raw : null,
    fatal: false,
  );
}

// ─────────────────────────────────────────────────────────────────────────────

enum VoiceState { idle, listening, thinking, speaking, reconnecting, error }

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
  _OcError? _errorInfo;
  bool _isErrorToast = false;

  StreamSubscription<String>? _transcriptSub;

  // Pulse animation (idle → subtle, listening → medium, speaking → faster)
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // Spin animation for thinking state
  late AnimationController _spinCtrl;

  // Wave bars for listening state
  late AnimationController _waveCtrl;
  late List<Animation<double>> _waveAnims;

  // Toast notification (slide + fade)
  late AnimationController _toastCtrl;
  late Animation<double> _toastFade;
  late Animation<Offset> _toastSlide;
  String _toastMessage = '';
  Timer? _toastTimer;

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

    _toastCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _toastFade = CurvedAnimation(parent: _toastCtrl, curve: Curves.easeOut);
    _toastSlide = Tween<Offset>(
      begin: const Offset(0, 1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _toastCtrl, curve: Curves.easeOut));

    _listenToStt();
  }

  void _showToast(String message, {bool isError = false}) {
    _toastTimer?.cancel();
    setState(() {
      _toastMessage = message;
      _isErrorToast = isError;
    });
    _toastCtrl.forward(from: 0);
    _toastTimer = Timer(const Duration(milliseconds: 3000), () {
      if (mounted) _toastCtrl.reverse();
    });
  }

  void _listenToStt() {
    _transcriptSub = _stt.transcripts.listen((event) async {
      // ── Reconnection events ────────────────────────────────────────────
      if (event == '__RECONNECTING__') {
        if (mounted && _voiceState != VoiceState.idle) {
          setState(() {
            _voiceState = VoiceState.reconnecting;
            _statusText = 'Reconnecting...';
          });
        }
        return;
      }

      if (event == '__RECONNECTED__') {
        if (mounted && _voiceState != VoiceState.idle) {
          setState(() {
            _voiceState = VoiceState.listening;
            _statusText = 'Listening...';
          });
          _showToast('Back online ✓');
        }
        return;
      }

      // STT gave up after max reconnect attempts
      if (event == '__STT_FAILED__') {
        if (mounted) {
          const err = _OcError(
            message: 'Speech recognition unavailable',
            hint: 'Deepgram couldn\'t reconnect. Check your key in Settings.',
            needsSettings: true,
            fatal: true,
          );
          setState(() {
            _voiceState = VoiceState.error;
            _statusText = err.message;
            _errorInfo = err;
          });
        }
        return;
      }

      // ── Barge-in: user started speaking during TTS playback ───────────────
      // SpeechStarted fires at voice onset (before a transcript exists) so
      // the cut is immediate. We fade TTS, patch history, then resume.
      if (event == '__SPEECH_STARTED__') {
        if (_voiceState == VoiceState.speaking) {
          await _handleBargeIn();
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

      // Only reset to listening if barge-in hasn't already taken over.
      // (barge-in sets _voiceState = listening + _processingTurn = false;
      // we don't want to stomp the live transcript it's already capturing)
      if (mounted && _voiceState == VoiceState.speaking) {
        setState(() {
          _voiceState = VoiceState.listening;
          _statusText = 'Listening...';
          _transcript = '';
        });
      }
    } catch (e) {
      _spinCtrl.stop();
      final err = _classifyError(e);
      if (err.fatal) {
        // Stop session and surface the error with actionable guidance
        await _stt.stop();
        if (mounted) {
          setState(() {
            _voiceState = VoiceState.error;
            _statusText = err.message;
            _errorInfo = err;
            _processingTurn = false;
          });
        }
        return; // skip the finally processingTurn=false (already set)
      } else {
        // Transient — show error toast and keep listening so user can retry
        if (mounted) {
          _showToast(err.message, isError: true);
          setState(() {
            _voiceState = VoiceState.listening;
            _statusText = 'Listening...';
          });
        }
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
      _errorInfo = null;
    });
    try {
      await _stt.start();
    } catch (e) {
      final err = _classifyError(e);
      if (mounted) {
        setState(() {
          _voiceState = VoiceState.error;
          _statusText = err.message;
          _errorInfo = err;
        });
      }
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
      _errorInfo = null;
    });
  }

  /// Barge-in handler: user spoke while assistant was talking.
  /// - Fades TTS to silence (~150ms, feels like being heard not cut off)
  /// - Patches history so LLM knows the response was interrupted
  /// - Calls bargeIn() on STT — skips grace period, immediately accepts speech
  /// - Deepgram already has the user's audio buffered, next turn fires normally
  Future<void> _handleBargeIn() async {
    if (_voiceState != VoiceState.speaking) return;

    // Unlock turn processing immediately (don't wait for TTS future to resolve)
    _processingTurn = false;
    _spinCtrl.stop();

    // Patch LLM history: mark the last response as interrupted so the LLM
    // has full conversational context and can respond naturally to the cut-in.
    if (_lastResponse.isNotEmpty) {
      _llm.updateLastAssistantMessage('$_lastResponse [interrupted by user]');
    }

    // Fade TTS out (~150ms) — sounds like the assistant heard you and trailed
    // off, rather than being hard-stopped mid-word.
    await _tts.fadeAndStop();

    // Tell STT to accept speech immediately (skip the 800ms echo grace period).
    _stt.bargeIn();

    if (mounted) {
      setState(() {
        _voiceState = VoiceState.listening;
        _statusText = 'Listening...';
        _transcript = '';
      });
    }
  }

  // ── State-derived values ──────────────────────────────────────────────────

  Color get _stateColor => switch (_voiceState) {
        VoiceState.idle => _kBorder,
        VoiceState.listening => _kGold,
        VoiceState.thinking => _kGold,
        VoiceState.speaking => _kBlue,
        VoiceState.reconnecting => _kDimGold,
        VoiceState.error => _kRed,
      };

  IconData get _stateIcon => switch (_voiceState) {
        VoiceState.idle || VoiceState.error => Icons.mic_none_rounded,
        VoiceState.listening => Icons.mic_rounded,
        VoiceState.thinking => Icons.mic_rounded,
        VoiceState.speaking => Icons.volume_up_rounded,
        VoiceState.reconnecting => Icons.wifi_off_rounded,
      };

  bool get _isPulsing =>
      _voiceState == VoiceState.listening ||
      _voiceState == VoiceState.speaking ||
      _voiceState == VoiceState.reconnecting;

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isError = _voiceState == VoiceState.error;
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildHeader(),
                Spacer(flex: isError ? 1 : 2),
                _buildTranscript(),
                SizedBox(height: isError ? 28 : 48),
                _buildMicButton(),
                SizedBox(height: isError ? 18 : 32),
                _buildStatusLabel(),
                Spacer(flex: isError ? 2 : 3),
                _buildResponseText(),
              ],
            ),
            _buildToast(),
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
    if (_voiceState == VoiceState.error && _errorInfo != null) {
      return _buildErrorPanel(_errorInfo!);
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Text(
        _statusText,
        key: ValueKey(_statusText),
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: _kTextMuted,
          fontSize: 13,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }

  Widget _buildErrorPanel(_OcError err) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Headline
        Text(
          err.message,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _kRed,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.3,
          ),
        ),
        // Hint
        if (err.hint != null) ...[
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              err.hint!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _kTextMuted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        // Action buttons
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildErrorButton(
              label: 'Retry',
              icon: Icons.refresh_rounded,
              onTap: _startSession,
            ),
            if (err.needsSettings) ...[
              const SizedBox(width: 12),
              _buildErrorButton(
                label: 'Settings',
                icon: Icons.tune_rounded,
                onTap: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const OnboardingScreen()),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildErrorButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: _kSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _kBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: _kTextMuted),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: _kTextMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.3,
              ),
            ),
          ],
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

  // ── Toast ─────────────────────────────────────────────────────────────────

  Widget _buildToast() {
    final color = _isErrorToast ? _kRed : _kGreen;
    final icon  = _isErrorToast ? Icons.error_outline_rounded : Icons.wifi_rounded;
    return Positioned(
      bottom: 32,
      left: 0,
      right: 0,
      child: FadeTransition(
        opacity: _toastFade,
        child: SlideTransition(
          position: _toastSlide,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2535),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: color.withOpacity(0.4)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 8),
                  Text(
                    _toastMessage,
                    style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _toastCtrl.dispose();
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
