import 'package:flutter/material.dart';
import 'ui/voice_screen.dart';

void main() {
  runApp(const OCVoiceApp());
}

class OCVoiceApp extends StatelessWidget {
  const OCVoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OCVoice',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF1DB954),
        ),
      ),
      home: const VoiceScreen(),
    );
  }
}
