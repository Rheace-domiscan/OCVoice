import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'settings_service.dart';

class OpenClawClient {
  final List<Map<String, String>> _history = [];

  /// Send a user message and stream the assistant's response text.
  Stream<String> chat(String userMessage) async* {
    _history.add({'role': 'user', 'content': userMessage});

    final s = SettingsService.instance;
    final messages = [
      {
        'role': 'system',
        'content': 'You are a voice assistant powered by OpenClaw. '
            'Be concise — your responses will be spoken aloud. '
            'Avoid markdown, bullet points, or formatting. '
            'Respond in natural spoken language.',
      },
      ..._history,
    ];

    final uri = Uri.parse('${s.gatewayUrl}/v1/chat/completions');

    final request = http.Request('POST', uri)
      ..headers['Authorization'] = 'Bearer ${s.gatewayToken}'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': 'openclaw',
        'messages': messages,
        'stream': true,
      });

    final response = await http.Client().send(request);

    if (response.statusCode != 200) {
      throw Exception(
        'OpenClaw gateway error: ${response.statusCode}',
      );
    }

    final buffer = StringBuffer();

    await for (final chunk in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!chunk.startsWith('data: ')) continue;
      final payload = chunk.substring(6).trim();
      if (payload == '[DONE]') break;

      try {
        final json = jsonDecode(payload) as Map<String, dynamic>;
        final delta =
            json['choices']?[0]?['delta']?['content'] as String? ?? '';
        if (delta.isNotEmpty) {
          buffer.write(delta);
          yield delta;
        }
      } catch (_) {}
    }

    // Save assistant response to history
    _history.add({'role': 'assistant', 'content': buffer.toString()});
  }

  void clearHistory() => _history.clear();
}
