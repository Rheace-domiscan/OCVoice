sealed class SttEvent {
  const SttEvent();
}

class SttReconnecting extends SttEvent {
  const SttReconnecting();
}

class SttReconnected extends SttEvent {
  const SttReconnected();
}

class SttFailed extends SttEvent {
  const SttFailed();
}

class SttSpeechStarted extends SttEvent {
  const SttSpeechStarted();
}

class SttSpeechFinal extends SttEvent {
  const SttSpeechFinal(this.text);
  final String text;
}

class SttTranscriptPartial extends SttEvent {
  const SttTranscriptPartial(this.text);
  final String text;
}

class SttTranscriptFinal extends SttEvent {
  const SttTranscriptFinal(this.text);
  final String text;
}
