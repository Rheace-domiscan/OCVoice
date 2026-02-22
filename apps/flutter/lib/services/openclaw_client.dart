import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

class OpenClawClient {
  final List<Map<String, String>> _history = [];

  /// Send a user message and stream the assistant's response text.
  Stream<String> chat(String userMessage) async* {
    _history.add({'role': 'user', 'content': userMessage});

    final messages = [
      {'role': 'system', 'content': AppConfig.openclawSystemPrompt},
      ..._history,
    ];

    final uri = Uri.parse(
      '${AppConfig.openclawGatewayUrl}/v1/chat/completions',
    );

    final request = http.Request('POST', uri)
      ..headers['Authorization'] = 'Bearer ${AppConfig.openclawGatewayToken}'
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': AppConfig.openclawModel,
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
