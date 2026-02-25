import 'dart:async';

import 'package:flutter/material.dart';

import 'voice/voice_controller.dart';
import 'voice/voice_models.dart';
import 'voice/voice_theme.dart';
import 'voice/widgets/voice_widgets.dart';

class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen>
    with TickerProviderStateMixin {
  VoiceController? _controller;
  VoiceViewState _viewState = VoiceViewState.initial();

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  late AnimationController _spinCtrl;

  late AnimationController _waveCtrl;
  late List<Animation<double>> _waveAnims;

  late AnimationController _toastCtrl;
  late Animation<double> _toastFade;
  late Animation<Offset> _toastSlide;
  String _toastMessage = '';
  bool _isErrorToast = false;
  Timer? _toastTimer;

  @override
  void initState() {
    super.initState();

    _viewState = VoiceViewState.initial();
    _ensureController();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 0.94,
      end: 1.06,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _spinCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _waveCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _waveAnims = List.generate(4, (i) {
      final start = i * 0.15;
      return Tween<double>(begin: 0.2, end: 1.0).animate(
        CurvedAnimation(
          parent: _waveCtrl,
          curve: Interval(
            start,
            (start + 0.7).clamp(0.0, 1.0),
            curve: Curves.easeInOut,
          ),
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
  }

  void _ensureController() {
    if (_controller != null) return;
    final controller = VoiceController(onToast: _showToast);
    _controller = controller;
    controller.state.addListener(_onControllerStateChanged);
    _viewState = controller.state.value;
  }

  void _onControllerStateChanged() {
    if (!mounted || _controller == null) return;
    final next = _controller!.state.value;

    if (next.voiceState == VoiceState.thinking) {
      _spinCtrl.repeat();
    } else {
      _spinCtrl.stop();
    }

    setState(() => _viewState = next);
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

  Color get _stateColor => switch (_viewState.voiceState) {
    VoiceState.idle => kBorder,
    VoiceState.listening => kGold,
    VoiceState.thinking => kGold,
    VoiceState.speaking => kBlue,
    VoiceState.reconnecting => kDimGold,
    VoiceState.error => kRed,
  };

  IconData get _stateIcon => switch (_viewState.voiceState) {
    VoiceState.idle || VoiceState.error => Icons.mic_none_rounded,
    VoiceState.listening => Icons.mic_rounded,
    VoiceState.thinking => Icons.mic_rounded,
    VoiceState.speaking => Icons.volume_up_rounded,
    VoiceState.reconnecting => Icons.wifi_off_rounded,
  };

  bool get _isPulsing =>
      _viewState.voiceState == VoiceState.listening ||
      _viewState.voiceState == VoiceState.speaking ||
      _viewState.voiceState == VoiceState.reconnecting;

  @override
  Widget build(BuildContext context) {
    _ensureController();
    final controller = _controller!;
    final isError = _viewState.voiceState == VoiceState.error;
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                const VoiceHeader(),
                Spacer(flex: isError ? 1 : 2),
                VoiceTranscript(transcript: _viewState.transcript),
                SizedBox(height: isError ? 28 : 48),
                VoiceMicButton(
                  onTap: controller.toggleSession,
                  voiceState: _viewState.voiceState,
                  stateColor: _stateColor,
                  stateIcon: _stateIcon,
                  isPulsing: _isPulsing,
                  pulseAnim: _pulseAnim,
                  spinCtrl: _spinCtrl,
                  waveAnims: _waveAnims,
                ),
                SizedBox(height: isError ? 18 : 32),
                VoiceStatusPanel(
                  voiceState: _viewState.voiceState,
                  statusText: _viewState.statusText,
                  errorInfo: _viewState.errorInfo,
                  onRetry: controller.startSession,
                ),
                Spacer(flex: isError ? 2 : 3),
                VoiceResponseText(response: _viewState.lastResponse),
              ],
            ),
            VoiceToast(
              message: _toastMessage,
              isError: _isErrorToast,
              fade: _toastFade,
              slide: _toastSlide,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _toastCtrl.dispose();
    _controller?.state.removeListener(_onControllerStateChanged);
    _controller?.dispose();
    _pulseCtrl.dispose();
    _spinCtrl.dispose();
    _waveCtrl.dispose();
    super.dispose();
  }
}
