import 'voice_error.dart';

enum VoiceState { idle, listening, thinking, speaking, reconnecting, error }

class VoiceViewState {
  final VoiceState voiceState;
  final String statusText;
  final String transcript;
  final String lastResponse;
  final OcError? errorInfo;

  const VoiceViewState({
    required this.voiceState,
    required this.statusText,
    required this.transcript,
    required this.lastResponse,
    this.errorInfo,
  });

  factory VoiceViewState.initial() => const VoiceViewState(
    voiceState: VoiceState.idle,
    statusText: 'Tap to speak',
    transcript: '',
    lastResponse: '',
  );

  VoiceViewState copyWith({
    VoiceState? voiceState,
    String? statusText,
    String? transcript,
    String? lastResponse,
    OcError? errorInfo,
    bool clearError = false,
  }) {
    return VoiceViewState(
      voiceState: voiceState ?? this.voiceState,
      statusText: statusText ?? this.statusText,
      transcript: transcript ?? this.transcript,
      lastResponse: lastResponse ?? this.lastResponse,
      errorInfo: clearError ? null : (errorInfo ?? this.errorInfo),
    );
  }
}
