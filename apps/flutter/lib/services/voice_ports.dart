import 'stt_events.dart';

abstract interface class SttService {
  Stream<SttEvent> get events;
  Future<void> start();
  Future<void> stop();
  void muteMic();
  void unmuteMic();
  void bargeIn();
  void dispose();
}

abstract interface class LlmService {
  Stream<String> chat(String userMessage);
  void clearHistory();
  void updateLastAssistantMessage(String text);
}

abstract interface class TtsService {
  Future<void> speak(String text);
  Future<void> stop();
  Future<void> fadeAndStop();
  void dispose();
}
