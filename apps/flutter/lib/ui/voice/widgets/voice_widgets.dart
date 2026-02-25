import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../onboarding_screen.dart';
import '../voice_error.dart';
import '../voice_models.dart';
import '../voice_theme.dart';

class VoiceHeader extends StatelessWidget {
  const VoiceHeader({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 20, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'O C V o i c e',
            style: TextStyle(
              color: kTextMuted,
              fontSize: 13,
              letterSpacing: 4,
              fontWeight: FontWeight.w300,
            ),
          ),
          IconButton(
            onPressed: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const OnboardingScreen()),
              );
            },
            icon: const Icon(Icons.tune_rounded, size: 20, color: kTextDim),
            tooltip: 'Settings',
          ),
        ],
      ),
    );
  }
}

class VoiceTranscript extends StatelessWidget {
  const VoiceTranscript({super.key, required this.transcript});

  final String transcript;

  @override
  Widget build(BuildContext context) {
    if (transcript.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Text(
        transcript,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: kTextSecondary,
          fontSize: 16,
          height: 1.6,
          fontWeight: FontWeight.w300,
        ),
      ),
    );
  }
}

class VoiceMicButton extends StatelessWidget {
  const VoiceMicButton({
    super.key,
    required this.onTap,
    required this.voiceState,
    required this.stateColor,
    required this.stateIcon,
    required this.isPulsing,
    required this.pulseAnim,
    required this.spinCtrl,
    required this.waveAnims,
  });

  final VoidCallback onTap;
  final VoiceState voiceState;
  final Color stateColor;
  final IconData stateIcon;
  final bool isPulsing;
  final Animation<double> pulseAnim;
  final AnimationController spinCtrl;
  final List<Animation<double>> waveAnims;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedBuilder(
        animation: Listenable.merge([pulseAnim, spinCtrl]),
        builder: (context, child) {
          final scale = isPulsing ? pulseAnim.value : 1.0;

          return Transform.scale(
            scale: scale,
            child: SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  if (voiceState != VoiceState.idle)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 400),
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: stateColor.withValues(alpha: 0.18),
                            blurRadius: 40,
                            spreadRadius: 12,
                          ),
                        ],
                      ),
                    ),

                  if (voiceState == VoiceState.thinking)
                    RotationTransition(
                      turns: spinCtrl,
                      child: CustomPaint(
                        size: const Size(130, 130),
                        painter: _ArcPainter(color: kGold),
                      ),
                    ),

                  AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    width: 112,
                    height: 112,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kSurface,
                      border: Border.all(
                        color: stateColor,
                        width: voiceState == VoiceState.idle ? 1 : 1.5,
                      ),
                    ),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: voiceState == VoiceState.listening
                            ? _WaveBars(anims: waveAnims, color: kGold)
                            : Icon(
                                stateIcon,
                                key: ValueKey(voiceState),
                                color: voiceState == VoiceState.idle
                                    ? kTextDim
                                    : stateColor,
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
}

class VoiceStatusPanel extends StatelessWidget {
  const VoiceStatusPanel({
    super.key,
    required this.voiceState,
    required this.statusText,
    required this.errorInfo,
    required this.onRetry,
  });

  final VoiceState voiceState;
  final String statusText;
  final OcError? errorInfo;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (voiceState == VoiceState.error && errorInfo != null) {
      final err = errorInfo!;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            err.message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: kRed,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
          if (err.hint != null) ...[
            const SizedBox(height: 5),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                err.hint!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: kTextMuted,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ErrorButton(
                label: 'Retry',
                icon: Icons.refresh_rounded,
                onTap: onRetry,
              ),
              if (err.needsSettings) ...[
                const SizedBox(width: 12),
                _ErrorButton(
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

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: Text(
        statusText,
        key: ValueKey(statusText),
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: kTextMuted,
          fontSize: 13,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }
}

class VoiceResponseText extends StatelessWidget {
  const VoiceResponseText({super.key, required this.response});

  final String response;

  @override
  Widget build(BuildContext context) {
    if (response.isEmpty) return const SizedBox(height: 44);
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 0, 36, 44),
      child: Text(
        response,
        textAlign: TextAlign.center,
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: kTextDim,
          fontSize: 13,
          height: 1.7,
          fontWeight: FontWeight.w300,
        ),
      ),
    );
  }
}

class VoiceToast extends StatelessWidget {
  const VoiceToast({
    super.key,
    required this.message,
    required this.isError,
    required this.fade,
    required this.slide,
  });

  final String message;
  final bool isError;
  final Animation<double> fade;
  final Animation<Offset> slide;

  @override
  Widget build(BuildContext context) {
    final color = isError ? kRed : kGreen;
    final icon = isError ? Icons.error_outline_rounded : Icons.wifi_rounded;
    return Positioned(
      bottom: 32,
      left: 0,
      right: 0,
      child: FadeTransition(
        opacity: fade,
        child: SlideTransition(
          position: slide,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2535),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: color.withValues(alpha: 0.4)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
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
                    message,
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
}

class _ErrorButton extends StatelessWidget {
  const _ErrorButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: kBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: kTextMuted),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: kTextMuted,
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
}

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

class _ArcPainter extends CustomPainter {
  const _ArcPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.6)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawArc(rect, 0, math.pi * 1.3, false, paint);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color;
}
