import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import 'settings_service.dart';
import 'voice_ports.dart';

class OpenClawClient implements LlmService {
  // ── Context window config ──────────────────────────────────────────────────
  // Voice exchanges are short (~100 tokens each) but we still cap the window
  // to control cost and keep LLM responses fast.
  //
  // Strategy: sliding window with an "anchor" — always keep the first
  // kAnchorMessages entries (often contain user name/topic that anchor the
  // whole session) plus the most recent kMaxMessages - kAnchorMessages.
  //
  // At ~100 tokens/message average:
  //   20 messages ≈ 2000 tokens history + ~50 system + response budget
  static const int kMaxMessages = 20; // total history entries to keep
  static const int kAnchorMessages = 2; // first N entries always preserved

  final List<Map<String, String>> _history = [];

  // ── Observable state ───────────────────────────────────────────────────────

  int get historyLength => _history.length;

  /// Rough token estimate (chars / 4). Useful for debug / cost monitoring.
  int get estimatedTokens {
    final systemTokens = 60; // approximate system prompt
    final historyTokens = _history.fold<int>(
      0,
      (sum, m) => sum + ((m['content']?.length ?? 0) ~/ 4),
    );
    return systemTokens + historyTokens;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Send a user message and stream the assistant's response text.
  @override
  Stream<String> chat(String userMessage) async* {
    _history.add({'role': 'user', 'content': userMessage});

    // Trim before sending — keeps context window bounded without losing
    // the opening exchanges that often anchor the whole conversation.
    _trimHistory();

    final s = SettingsService.instance;
    final messages = [
      {
        'role': 'system',
        'content':
            'You are a voice assistant powered by OpenClaw. '
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
      throw Exception('OpenClaw gateway error: ${response.statusCode}');
    }

    final buffer = StringBuffer();

    await for (final chunk
        in response.stream
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

  @override
  void clearHistory() => _history.clear();

  /// Patch the last assistant message in history.
  /// Called on barge-in: appends '[interrupted by user]' so the LLM has
  /// full conversational context and can respond naturally to the cut-in.
  @override
  void updateLastAssistantMessage(String text) {
    for (int i = _history.length - 1; i >= 0; i--) {
      if (_history[i]['role'] == 'assistant') {
        _history[i] = {'role': 'assistant', 'content': text};
        return;
      }
    }
    _history.add({'role': 'assistant', 'content': text});
  }

  // ── Test accessors ────────────────────────────────────────────────────────
  // These expose internals for unit testing only. Do not use in production.

  @visibleForTesting
  List<Map<String, String>> get testHistory => List.unmodifiable(_history);

  @visibleForTesting
  void testAddToHistory(Map<String, String> entry) => _history.add(entry);

  @visibleForTesting
  void testTrim() => _trimHistory();

  // ── Context trimming ───────────────────────────────────────────────────────

  /// Trim _history to kMaxMessages while preserving the first kAnchorMessages.
  ///
  /// Example with kMaxMessages=20, kAnchorMessages=2, and 25 messages:
  ///   Keep: [0,1] (anchors) + [7..24] (last 18 of the remainder)
  ///   Drop: [2..6] (oldest non-anchor entries)
  ///
  /// This preserves early conversation context (user's name, stated goals)
  /// while ensuring the window stays bounded regardless of session length.
  void _trimHistory() {
    if (_history.length <= kMaxMessages) return;

    final anchor = _history.take(kAnchorMessages).toList();
    final tail = _history.skip(kAnchorMessages).toList();

    final keepFromTail = kMaxMessages - kAnchorMessages;
    final trimmed = tail.length > keepFromTail
        ? tail.sublist(tail.length - keepFromTail)
        : tail;

    _history
      ..clear()
      ..addAll(anchor)
      ..addAll(trimmed);
  }
}
