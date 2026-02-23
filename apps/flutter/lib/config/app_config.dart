// OCVoice App Configuration
// Keys are loaded here for development. In production, use flutter_secure_storage
// and an onboarding screen so users supply their own gateway credentials.

class AppConfig {
  // Deepgram STT
  static const String deepgramApiKey =
      '9cde2aa572e4db83bde00f18dec61ef61dd07f7a';
  static const String deepgramWsUrl =
      'wss://api.deepgram.com/v1/listen'
      '?model=nova-2'
      '&encoding=linear16'
      '&sample_rate=16000'
      '&channels=1'
      '&interim_results=true'
      '&endpointing=500'
      '&utterance_end_ms=1500';

  // OpenClaw Gateway
  static const String openclawGatewayUrl =
      'https://rheaces-macbook-pro-1.taildb31e4.ts.net';
  static const String openclawGatewayToken =
      '2057c13648d1ae44f9d12ed3c14bdf398d6a1efac945fcbd';
  static const String openclawModel = 'openclaw';
  static const String openclawSystemPrompt =
      'You are a voice assistant powered by OpenClaw. '
      'Be concise — your responses will be spoken aloud. '
      'Avoid markdown, bullet points, or formatting. '
      'Respond in natural spoken language.';

  // ElevenLabs TTS
  static const String elevenLabsApiKey =
      'sk_558c7d2b1c3f84ae1ed558455a733d7de39a94e789c73480';
  static const String elevenLabsVoiceId = 'tnSpp4vdxKPjI9w0GnoV'; // Custom voice
  static const String elevenLabsModel = 'eleven_turbo_v2_5';
  static String get elevenLabsTtsUrl =>
      'https://api.elevenlabs.io/v1/text-to-speech/$elevenLabsVoiceId/stream';
}
