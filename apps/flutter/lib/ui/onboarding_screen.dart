import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/settings_service.dart';
import 'voice_screen.dart';

// ── Palette ───────────────────────────────────────────────────────────────────
const _kBg = Color(0xFF090E1A);
const _kSurface = Color(0xFF111827);
const _kBorder = Color(0xFF1F2937);
const _kGold = Color(0xFFC9A96E);
const _kTextPrimary = Color(0xFFF1F5F9);
const _kTextSecondary = Color(0xFF94A3B8);
const _kTextMuted = Color(0xFF64748B);
const _kTextDim = Color(0xFF475569);
const _kInputBg = Color(0xFF0F172A);
const _kSuccess = Color(0xFF4ADE80);
const _kSuccessBg = Color(0xFF052E16);
const _kSuccessBorder = Color(0xFF166534);
const _kBlueAccent = Color(0xFF60A5FA);
const _kDisabled = Color(0xFF1F2937);
const _kDisabledText = Color(0xFF475569);

// ─────────────────────────────────────────────────────────────────────────────

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with SingleTickerProviderStateMixin {
  int _step = 0;
  static const int _kTotalSteps = 4;

  // Text controllers
  final _gatewayUrlCtrl = TextEditingController();
  final _gatewayTokenCtrl = TextEditingController();
  final _deepgramKeyCtrl = TextEditingController();
  final _elevenLabsKeyCtrl = TextEditingController();
  final _voiceIdCtrl = TextEditingController();

  // Visibility toggles
  bool _showToken = false;
  bool _showDgKey = false;
  bool _showElKey = false;

  // Step 3 test-connection state
  bool _testing = false;
  bool _testPassed = false;
  String? _testError;

  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();

    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();

    // Pre-fill from existing settings (e.g. returning to edit)
    final s = SettingsService.instance;
    _gatewayUrlCtrl.text = s.gatewayUrl;
    _gatewayTokenCtrl.text = s.gatewayToken;
    _deepgramKeyCtrl.text = s.deepgramKey;
    _elevenLabsKeyCtrl.text = s.elevenLabsKey;
    _voiceIdCtrl.text = s.voiceId;

    // Rebuild when any field changes (enables/disables Continue button)
    for (final c in [
      _gatewayUrlCtrl,
      _gatewayTokenCtrl,
      _deepgramKeyCtrl,
      _elevenLabsKeyCtrl,
    ]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    for (final c in [
      _gatewayUrlCtrl,
      _gatewayTokenCtrl,
      _deepgramKeyCtrl,
      _elevenLabsKeyCtrl,
      _voiceIdCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ── Navigation ─────────────────────────────────────────────────────────────

  void _next() {
    if (_step < _kTotalSteps - 1) {
      _fadeCtrl.reset();
      setState(() => _step++);
      _fadeCtrl.forward();
    }
  }

  void _back() {
    if (_step > 0) {
      _fadeCtrl.reset();
      setState(() => _step--);
      _fadeCtrl.forward();
    }
  }

  // ── Save & advance to done ─────────────────────────────────────────────────

  Future<void> _saveAndContinue() async {
    try {
      await SettingsService.instance.save(
        gatewayUrl: _gatewayUrlCtrl.text.trim(),
        gatewayToken: _gatewayTokenCtrl.text.trim(),
        deepgramKey: _deepgramKeyCtrl.text.trim(),
        elevenLabsKey: _elevenLabsKeyCtrl.text.trim(),
        voiceId: _voiceIdCtrl.text.trim(),
      );
    } catch (_) {
      // If secure storage fails (e.g. macOS keychain sandbox in debug mode),
      // settings are still cached in-memory — safe to proceed.
    } finally {
      _next();
    }
  }

  // ── Connection test ────────────────────────────────────────────────────────

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testPassed = false;
      _testError = null;
    });

    try {
      final s = SettingsService.instance;
      final uri = Uri.parse('${s.gatewayUrl}/v1/chat/completions');
      final response = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${s.gatewayToken}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'model': 'openclaw',
              'messages': [
                {'role': 'user', 'content': 'ping'},
              ],
              'max_tokens': 1,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 201) {
        setState(() {
          _testPassed = true;
          _testing = false;
        });
      } else {
        setState(() {
          _testError = 'Gateway returned ${response.statusCode}';
          _testing = false;
        });
      }
    } catch (e) {
      setState(() {
        _testError = e.toString().replaceFirst('Exception: ', '');
        _testing = false;
      });
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Column(
          children: [
            if (_step > 0) ...[
              const SizedBox(height: 8),
              _ProgressBar(step: _step, total: _kTotalSteps),
            ],
            Expanded(
              child: FadeTransition(
                opacity: _fadeAnim,
                child: _buildStep(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStep() {
    return switch (_step) {
      0 => _buildWelcome(),
      1 => _buildGatewayStep(),
      2 => _buildApisStep(),
      3 => _buildDoneStep(),
      _ => _buildWelcome(),
    };
  }

  // ── Step 0: Welcome ────────────────────────────────────────────────────────

  Widget _buildWelcome() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 2),

          // Logomark
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: _kSurface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _kBorder),
            ),
            child: const Center(
              child: Icon(Icons.mic, color: _kGold, size: 28),
            ),
          ),

          const SizedBox(height: 36),

          const Text(
            'OCVoice',
            style: TextStyle(
              color: _kTextPrimary,
              fontSize: 38,
              fontWeight: FontWeight.w200,
              letterSpacing: 3,
            ),
          ),

          const SizedBox(height: 14),

          const Text(
            'Your OpenClaw AI,\nactivated by voice.',
            style: TextStyle(
              color: _kTextSecondary,
              fontSize: 20,
              height: 1.5,
              fontWeight: FontWeight.w300,
            ),
          ),

          const SizedBox(height: 20),

          const Text(
            'You\'ll need your OpenClaw gateway credentials '
            'and voice API keys. Takes about two minutes.',
            style: TextStyle(
              color: _kTextMuted,
              fontSize: 14,
              height: 1.7,
            ),
          ),

          const Spacer(flex: 3),

          _PrimaryButton(label: 'Get started', onTap: _next),

          const SizedBox(height: 44),
        ],
      ),
    );
  }

  // ── Step 1: Gateway ────────────────────────────────────────────────────────

  Widget _buildGatewayStep() {

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 44),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          _StepLabel(step: '01', label: 'Gateway'),
          const SizedBox(height: 10),
          const Text(
            'Connect to your\nOpenClaw gateway.',
            style: TextStyle(
              color: _kTextPrimary,
              fontSize: 28,
              fontWeight: FontWeight.w300,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Your gateway runs on your Mac and is exposed via '
            'Tailscale Funnel or another tunnel.',
            style: TextStyle(color: _kTextMuted, fontSize: 13, height: 1.7),
          ),

          const SizedBox(height: 40),

          _FieldLabel('Gateway URL'),
          const SizedBox(height: 8),
          _InputField(
            controller: _gatewayUrlCtrl,
            hint: 'https://your-machine.tailscale.net',
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 6),
          const Text(
            'e.g. https://my-macbook.taildb31e4.ts.net',
            style: TextStyle(color: _kTextDim, fontSize: 11),
          ),

          const SizedBox(height: 28),

          _FieldLabel('Bearer token'),
          const SizedBox(height: 8),
          _InputField(
            controller: _gatewayTokenCtrl,
            hint: 'Your OpenClaw gateway token',
            obscure: !_showToken,
            suffix: _EyeToggle(
              visible: _showToken,
              onToggle: () => setState(() => _showToken = !_showToken),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Found in OpenClaw settings → Gateway → Auth token',
            style: TextStyle(color: _kTextDim, fontSize: 11),
          ),

          const SizedBox(height: 52),

          _PrimaryButton(label: 'Continue', onTap: _next),
          const SizedBox(height: 16),
          _BackButton(onTap: _back),
        ],
      ),
    );
  }

  // ── Step 2: APIs ───────────────────────────────────────────────────────────

  Widget _buildApisStep() {

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 24, 32, 44),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          _StepLabel(step: '02', label: 'Voice services'),
          const SizedBox(height: 10),
          const Text(
            'Add your voice\nAPI keys.',
            style: TextStyle(
              color: _kTextPrimary,
              fontSize: 28,
              fontWeight: FontWeight.w300,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Deepgram handles speech recognition. ElevenLabs handles voice synthesis.',
            style: TextStyle(color: _kTextMuted, fontSize: 13, height: 1.7),
          ),

          const SizedBox(height: 36),

          // Deepgram card
          _ServiceCard(
            label: 'Deepgram',
            sublabel: 'Speech recognition',
            accentColor: _kBlueAccent,
            icon: Icons.graphic_eq,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FieldLabel('API key'),
                const SizedBox(height: 8),
                _InputField(
                  controller: _deepgramKeyCtrl,
                  hint: 'Deepgram API key',
                  obscure: !_showDgKey,
                  suffix: _EyeToggle(
                    visible: _showDgKey,
                    onToggle: () => setState(() => _showDgKey = !_showDgKey),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'deepgram.com — free 200 hr/yr tier available',
                  style: TextStyle(color: _kTextDim, fontSize: 11),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ElevenLabs card
          _ServiceCard(
            label: 'ElevenLabs',
            sublabel: 'Voice synthesis',
            accentColor: _kGold,
            icon: Icons.record_voice_over,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FieldLabel('API key'),
                const SizedBox(height: 8),
                _InputField(
                  controller: _elevenLabsKeyCtrl,
                  hint: 'ElevenLabs API key (sk_...)',
                  obscure: !_showElKey,
                  suffix: _EyeToggle(
                    visible: _showElKey,
                    onToggle: () => setState(() => _showElKey = !_showElKey),
                  ),
                ),
                const SizedBox(height: 20),
                _FieldLabel('Voice ID  (optional)'),
                const SizedBox(height: 8),
                _InputField(
                  controller: _voiceIdCtrl,
                  hint: 'tnSpp4vdxKPjI9w0GnoV',
                ),
                const SizedBox(height: 6),
                const Text(
                  'Find voices at elevenlabs.io/voice-library',
                  style: TextStyle(color: _kTextDim, fontSize: 11),
                ),
              ],
            ),
          ),

          const SizedBox(height: 52),

          _PrimaryButton(label: 'Save & continue', onTap: _saveAndContinue),
          const SizedBox(height: 16),
          _BackButton(onTap: _back),
        ],
      ),
    );
  }

  // ── Step 3: Done ───────────────────────────────────────────────────────────

  Widget _buildDoneStep() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Spacer(flex: 2),

          // Checkmark icon
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: _kSuccessBg,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _kSuccessBorder),
            ),
            child: const Center(
              child: Icon(Icons.check_rounded, color: _kSuccess, size: 30),
            ),
          ),

          const SizedBox(height: 36),

          const Text(
            "You're all set.",
            style: TextStyle(
              color: _kTextPrimary,
              fontSize: 34,
              fontWeight: FontWeight.w200,
              letterSpacing: 0.5,
            ),
          ),

          const SizedBox(height: 14),

          const Text(
            'Your voice assistant is ready. '
            'Tap the mic and start talking to OpenClaw.',
            style: TextStyle(
              color: _kTextSecondary,
              fontSize: 16,
              height: 1.7,
            ),
          ),

          const SizedBox(height: 28),

          // Optional gateway test
          if (!_testPassed) ...[
            _TestConnectionTile(
              testing: _testing,
              error: _testError,
              onTest: _testConnection,
            ),
            const SizedBox(height: 12),
          ],

          if (_testPassed)
            _StatusBadge(
              icon: Icons.check_circle_outline,
              color: _kSuccess,
              label: 'Gateway reachable',
            ),

          const Spacer(flex: 3),

          _PrimaryButton(
            label: 'Start talking',
            onTap: () {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => const VoiceScreen()),
              );
            },
          ),

          const SizedBox(height: 44),
        ],
      ),
    );
  }
}

// ── Supporting widgets ────────────────────────────────────────────────────────

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.step, required this.total});

  final int step;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 0),
      child: Row(
        children: List.generate(total - 1, (i) {
          return Expanded(
            child: Container(
              margin: EdgeInsets.only(right: i < total - 2 ? 6 : 0),
              height: 2,
              decoration: BoxDecoration(
                color: i < step ? _kGold : _kBorder,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _StepLabel extends StatelessWidget {
  const _StepLabel({required this.step, required this.label});

  final String step;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          step,
          style: const TextStyle(
            color: _kGold,
            fontSize: 11,
            letterSpacing: 2,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          '/',
          style: TextStyle(color: _kBorder, fontSize: 11),
        ),
        const SizedBox(width: 8),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: _kTextMuted,
            fontSize: 11,
            letterSpacing: 2,
          ),
        ),
      ],
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: _kTextSecondary,
        fontSize: 12,
        letterSpacing: 0.5,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

class _InputField extends StatelessWidget {
  const _InputField({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.suffix,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final Widget? suffix;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: const TextStyle(
        color: _kTextPrimary,
        fontSize: 14,
        fontFamily: 'monospace',
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF374151), fontSize: 13),
        filled: true,
        fillColor: _kInputBg,
        suffixIcon: suffix,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: _kGold, width: 1.5),
        ),
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.label,
    required this.sublabel,
    required this.accentColor,
    required this.icon,
    required this.child,
  });

  final String label;
  final String sublabel;
  final Color accentColor;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _kSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: accentColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: accentColor, size: 16),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: _kTextPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    sublabel,
                    style: const TextStyle(
                      color: _kTextMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }
}

class _EyeToggle extends StatelessWidget {
  const _EyeToggle({required this.visible, required this.onToggle});

  final bool visible;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(
        visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        size: 18,
        color: _kTextMuted,
      ),
      onPressed: onToggle,
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        height: 54,
        decoration: BoxDecoration(
          color: enabled ? _kGold : _kDisabled,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: enabled ? _kBg : _kDisabledText,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  const _BackButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: const Center(
        child: Text(
          'Back',
          style: TextStyle(color: _kTextMuted, fontSize: 14),
        ),
      ),
    );
  }
}

class _TestConnectionTile extends StatelessWidget {
  const _TestConnectionTile({
    required this.testing,
    required this.error,
    required this.onTest,
  });

  final bool testing;
  final String? error;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: testing ? null : onTest,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        decoration: BoxDecoration(
          color: _kSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: error != null ? const Color(0xFF7F1D1D) : _kBorder,
          ),
        ),
        child: Row(
          children: [
            if (testing)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: _kGold,
                ),
              )
            else
              const Icon(Icons.wifi_tethering, size: 16, color: _kTextMuted),
            const SizedBox(width: 12),
            Expanded(
              child: error != null
                  ? Text(
                      error!,
                      style: const TextStyle(
                        color: Color(0xFFF87171),
                        fontSize: 12,
                      ),
                    )
                  : const Text(
                      'Test gateway connection',
                      style: TextStyle(color: _kTextSecondary, fontSize: 13),
                    ),
            ),
            if (!testing)
              const Text(
                'Test',
                style: TextStyle(
                  color: _kGold,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({
    required this.icon,
    required this.color,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: color, fontSize: 13)),
      ],
    );
  }
}
