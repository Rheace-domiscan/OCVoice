import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/deepgram_stt.dart';
import '../services/elevenlabs_tts.dart';
import '../services/openclaw_client.dart';
import 'voice/voice_error.dart';
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
  final _stt = DeepgramStt();
  final _llm = OpenClawClient();
  final _tts = ElevenLabsTts();

  bool _processingTurn = false;

  VoiceState _voiceState = VoiceState.idle;
  String _statusText = 'Tap to speak';
  String _transcript = '';
  String _lastResponse = '';
  String _lastHeardTranscript = '';
  OcError? _errorInfo;
  bool _isErrorToast = false;

  StreamSubscription<String>? _transcriptSub;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  late AnimationController _spinCtrl;

  late AnimationController _waveCtrl;
  late List<Animation<double>> _waveAnims;

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

      if (event == '__STT_FAILED__') {
        if (mounted) {
          const err = OcError(
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

      if (mounted && _voiceState == VoiceState.speaking) {
        setState(() {
          _voiceState = VoiceState.listening;
          _statusText = 'Listening...';
          _transcript = '';
        });
      }
    } catch (e) {
      _spinCtrl.stop();
      final err = classifyError(e);
      if (err.fatal) {
        await _stt.stop();
        if (mounted) {
          setState(() {
            _voiceState = VoiceState.error;
            _statusText = err.message;
            _errorInfo = err;
            _processingTurn = false;
          });
        }
        return;
      } else {
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
      final err = classifyError(e);
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

  Future<void> _handleBargeIn() async {
    if (_voiceState != VoiceState.speaking) return;

    _processingTurn = false;
    _spinCtrl.stop();

    if (_lastResponse.isNotEmpty) {
      _llm.updateLastAssistantMessage('$_lastResponse [interrupted by user]');
    }

    await _tts.fadeAndStop();

    _stt.bargeIn();

    if (mounted) {
      setState(() {
        _voiceState = VoiceState.listening;
        _statusText = 'Listening...';
        _transcript = '';
      });
    }
  }

  Color get _stateColor => switch (_voiceState) {
    VoiceState.idle => kBorder,
    VoiceState.listening => kGold,
    VoiceState.thinking => kGold,
    VoiceState.speaking => kBlue,
    VoiceState.reconnecting => kDimGold,
    VoiceState.error => kRed,
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

  @override
  Widget build(BuildContext context) {
    final isError = _voiceState == VoiceState.error;
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                const VoiceHeader(),
                Spacer(flex: isError ? 1 : 2),
                VoiceTranscript(transcript: _transcript),
                SizedBox(height: isError ? 28 : 48),
                VoiceMicButton(
                  onTap: _toggleSession,
                  voiceState: _voiceState,
                  stateColor: _stateColor,
                  stateIcon: _stateIcon,
                  isPulsing: _isPulsing,
                  pulseAnim: _pulseAnim,
                  spinCtrl: _spinCtrl,
                  waveAnims: _waveAnims,
                ),
                SizedBox(height: isError ? 18 : 32),
                VoiceStatusPanel(
                  voiceState: _voiceState,
                  statusText: _statusText,
                  errorInfo: _errorInfo,
                  onRetry: _startSession,
                ),
                Spacer(flex: isError ? 2 : 3),
                VoiceResponseText(response: _lastResponse),
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
    _transcriptSub?.cancel();
    _pulseCtrl.dispose();
    _spinCtrl.dispose();
    _waveCtrl.dispose();
    _stt.dispose();
    _tts.dispose();
    super.dispose();
  }
}
