import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocvoice/services/stt_events.dart';
import 'package:ocvoice/services/voice_ports.dart';
import 'package:ocvoice/ui/voice/voice_controller.dart';
import 'package:ocvoice/ui/voice/voice_models.dart';

class FakeStt implements SttService {
  final _events = StreamController<SttEvent>.broadcast();
  bool started = false;
  bool stopped = false;
  bool muted = false;
  bool unmuted = false;
  bool bargedIn = false;
  Exception? startError;

  @override
  Stream<SttEvent> get events => _events.stream;

  void emit(SttEvent e) => _events.add(e);

  @override
  Future<void> start() async {
    if (startError != null) throw startError!;
    started = true;
  }

  @override
  Future<void> stop() async => stopped = true;

  @override
  void muteMic() => muted = true;

  @override
  void unmuteMic() => unmuted = true;

  @override
  void bargeIn() => bargedIn = true;

  @override
  void dispose() => _events.close();
}

class FakeLlm implements LlmService {
  List<String> updates = [];
  String response = 'Hello from LLM';

  @override
  Stream<String> chat(String userMessage) async* {
    yield response;
  }

  @override
  void clearHistory() {}

  @override
  void updateLastAssistantMessage(String text) => updates.add(text);
}

class FakeTts implements TtsService {
  bool speakCalled = false;
  bool stopCalled = false;
  bool fadeCalled = false;
  Exception? speakError;
  Duration speakDelay = Duration.zero;

  @override
  Future<void> speak(String text) async {
    speakCalled = true;
    if (speakDelay > Duration.zero) {
      await Future<void>.delayed(speakDelay);
    }
    if (speakError != null) throw speakError!;
  }

  @override
  Future<void> stop() async => stopCalled = true;

  @override
  Future<void> fadeAndStop() async => fadeCalled = true;

  @override
  void dispose() {}
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  group('VoiceController', () {
    test('startSession moves to listening when STT starts', () async {
      final stt = FakeStt();
      final controller = VoiceController(
        stt: stt,
        llm: FakeLlm(),
        tts: FakeTts(),
      );

      await controller.startSession();

      expect(stt.started, true);
      expect(controller.state.value.voiceState, VoiceState.listening);
      expect(controller.state.value.statusText, 'Listening...');
      controller.dispose();
    });

    test('reconnect events update state and emit toast callback', () async {
      final stt = FakeStt();
      String? toast;
      final controller = VoiceController(
        stt: stt,
        llm: FakeLlm(),
        tts: FakeTts(),
        onToast: (msg, {isError = false}) => toast = msg,
      );

      await controller.startSession();
      stt.emit(const SttReconnecting());
      await _tick();
      expect(controller.state.value.voiceState, VoiceState.reconnecting);

      stt.emit(const SttReconnected());
      await _tick();
      expect(controller.state.value.voiceState, VoiceState.listening);
      expect(toast, 'Back online ✓');
      controller.dispose();
    });

    test(
      'speech final runs llm/tts pipeline and returns to listening',
      () async {
        final stt = FakeStt();
        final llm = FakeLlm()..response = 'Sure, done.';
        final tts = FakeTts();
        final controller = VoiceController(stt: stt, llm: llm, tts: tts);

        await controller.startSession();
        stt.emit(const SttSpeechFinal('What time is it'));
        await _tick();
        await _tick();

        expect(tts.speakCalled, true);
        expect(stt.muted, true);
        expect(stt.unmuted, true);
        expect(controller.state.value.voiceState, VoiceState.listening);
        expect(controller.state.value.lastResponse, 'Sure, done.');
        controller.dispose();
      },
    );

    test('barge-in during speaking fades TTS and returns listening', () async {
      final stt = FakeStt();
      final llm = FakeLlm()..response = 'Long response';
      final tts = FakeTts()..speakDelay = const Duration(milliseconds: 80);
      final controller = VoiceController(stt: stt, llm: llm, tts: tts);

      await controller.startSession();
      stt.emit(const SttSpeechFinal('Tell me a story'));
      await _tick();
      stt.emit(const SttSpeechStarted());
      await _tick();

      expect(tts.fadeCalled, true);
      expect(stt.bargedIn, true);
      expect(controller.state.value.voiceState, VoiceState.listening);
      expect(llm.updates.last, contains('[interrupted by user]'));
      controller.dispose();
    });

    test('fatal TTS error puts controller in error state', () async {
      final stt = FakeStt();
      final llm = FakeLlm();
      final tts = FakeTts()
        ..speakError = Exception('401 unauthorized elevenlabs');
      final controller = VoiceController(stt: stt, llm: llm, tts: tts);

      await controller.startSession();
      stt.emit(const SttSpeechFinal('say hi'));
      await _tick();
      await _tick();

      expect(controller.state.value.voiceState, VoiceState.error);
      expect(
        controller.state.value.statusText.toLowerCase(),
        contains('rejected'),
      );
      expect(stt.stopped, true);
      controller.dispose();
    });
  });
}
