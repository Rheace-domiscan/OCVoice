import 'package:flutter/material.dart';

import 'services/settings_service.dart';
import 'ui/onboarding_screen.dart';
import 'ui/voice_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load persisted settings before showing any UI
  await SettingsService.instance.load();
  runApp(const OCVoiceApp());
}

class OCVoiceApp extends StatelessWidget {
  const OCVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    final s = SettingsService.instance;
    // Route: onboarding if not configured, otherwise straight to voice
    final home = s.onboarded && s.isConfigured
        ? const VoiceScreen()
        : const OnboardingScreen();

    return MaterialApp(
      title: 'OCVoice',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF090E1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFC9A96E),
          surface: Color(0xFF111827),
        ),
      ),
      home: home,
    );
  }
}
