class OcError {
  final String message; // headline
  final String? hint; // sub-line (what to do)
  final bool needsSettings; // show "Settings" action button
  final bool fatal; // false = toast + keep listening; true = stop

  const OcError({
    required this.message,
    this.hint,
    this.needsSettings = false,
    this.fatal = true,
  });
}

OcError classifyError(dynamic e) {
  final s = e.toString().toLowerCase();

  // Microphone
  if (s.contains('permission') ||
      s.contains('microphone') ||
      s.contains('audio input')) {
    return const OcError(
      message: 'Mic access denied',
      hint: 'System Prefs → Privacy → Microphone → allow OCVoice',
      needsSettings: false,
    );
  }

  // 401 / auth — distinguish service
  if (s.contains('401') ||
      s.contains('unauthorized') ||
      s.contains('invalid api key')) {
    if (s.contains('openclaw') || s.contains('gateway')) {
      return const OcError(
        message: 'Gateway token rejected (401)',
        hint: 'Update your OpenClaw token in Settings',
        needsSettings: true,
      );
    }
    if (s.contains('elevenlabs') || s.contains('tts')) {
      return const OcError(
        message: 'ElevenLabs key rejected (401)',
        hint: 'Update your ElevenLabs key in Settings',
        needsSettings: true,
      );
    }
    return const OcError(
      message: 'Authentication failed',
      hint: 'Check your API keys in Settings',
      needsSettings: true,
    );
  }

  // Gateway down / transient server errors
  if (s.contains('openclaw') || s.contains('gateway')) {
    if (s.contains('503') ||
        s.contains('502') ||
        s.contains('504') ||
        s.contains('500')) {
      return const OcError(
        message: 'Gateway unreachable',
        hint: 'Is OpenClaw running? Check Tailscale.',
        fatal: false, // transient — keep listening, show toast
      );
    }
    return const OcError(
      message: 'Gateway error',
      hint: 'Check your gateway URL in Settings',
      needsSettings: true,
      fatal: false,
    );
  }

  // ElevenLabs / TTS transient
  if (s.contains('elevenlabs') || s.contains('tts error')) {
    return const OcError(
      message: 'Speech synthesis failed',
      hint: 'ElevenLabs may be down, or quota exceeded',
      fatal: false,
    );
  }

  // STT gave up after max reconnect attempts
  if (s.contains('__stt_failed__') ||
      (s.contains('deepgram') && s.contains('fail'))) {
    return const OcError(
      message: 'Speech recognition unavailable',
      hint: 'Check your Deepgram key in Settings',
      needsSettings: true,
    );
  }

  // Network / socket
  if (s.contains('socket') ||
      s.contains('network') ||
      s.contains('timeout') ||
      s.contains('connection refused') ||
      s.contains('connection reset')) {
    return const OcError(
      message: 'Network error',
      hint: 'Check your connection and try again',
      fatal: false,
    );
  }

  // Unknown — show abbreviated message
  final raw = e.toString();
  return OcError(
    message: 'Something went wrong',
    hint: raw.length <= 80 ? raw : null,
    fatal: false,
  );
}
