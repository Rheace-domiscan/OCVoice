import 'package:flutter_test/flutter_test.dart';
import 'package:ocvoice/services/openclaw_client.dart';

// We test the context-window management logic in isolation.
// The chat() method requires a live gateway — those are integration tests.
// Here we directly exercise trimming, patching, and clearing history via
// the reflected internal state exposed by historyLength / estimatedTokens.

void main() {
  group('OpenClawClient — context window management', () {
    late OpenClawClient client;

    setUp(() {
      client = OpenClawClient();
    });

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// Push N complete user+assistant exchange pairs into history.
    void addExchanges(int n) {
      for (int i = 0; i < n; i++) {
        client.testAddToHistory({'role': 'user',      'content': 'user message $i'});
        client.testAddToHistory({'role': 'assistant', 'content': 'assistant reply $i'});
      }
    }

    // ── Basic state ───────────────────────────────────────────────────────────

    test('starts with empty history', () {
      expect(client.historyLength, 0);
    });

    test('clearHistory resets to zero', () {
      addExchanges(3);
      expect(client.historyLength, 6);
      client.clearHistory();
      expect(client.historyLength, 0);
    });

    // ── Token estimate ────────────────────────────────────────────────────────

    test('estimatedTokens includes system prompt baseline', () {
      // Empty history — should still count the system prompt (~60 tokens)
      expect(client.estimatedTokens, greaterThan(0));
    });

    test('estimatedTokens grows with history', () {
      final before = client.estimatedTokens;
      addExchanges(5);
      expect(client.estimatedTokens, greaterThan(before));
    });

    // ── updateLastAssistantMessage ────────────────────────────────────────────

    test('updateLastAssistantMessage patches last assistant entry', () {
      client.testAddToHistory({'role': 'user',      'content': 'hello'});
      client.testAddToHistory({'role': 'assistant', 'content': 'hi there'});
      client.updateLastAssistantMessage('hi there [interrupted by user]');
      expect(
        client.testHistory.last['content'],
        'hi there [interrupted by user]',
      );
    });

    test('updateLastAssistantMessage does not create duplicate when patching', () {
      client.testAddToHistory({'role': 'user',      'content': 'hello'});
      client.testAddToHistory({'role': 'assistant', 'content': 'original'});
      final before = client.historyLength;
      client.updateLastAssistantMessage('patched');
      expect(client.historyLength, before); // no new entry added
    });

    test('updateLastAssistantMessage appends if no assistant message exists', () {
      client.testAddToHistory({'role': 'user', 'content': 'hello'});
      client.updateLastAssistantMessage('fallback');
      expect(client.historyLength, 2);
      expect(client.testHistory.last['content'], 'fallback');
    });

    // ── Sliding window trim ───────────────────────────────────────────────────

    test('history below kMaxMessages is not trimmed', () {
      addExchanges(4); // 8 messages — well below kMaxMessages=20
      expect(client.historyLength, 8);
    });

    test('history at exactly kMaxMessages is not trimmed', () {
      addExchanges(10); // 20 messages = exactly kMaxMessages=20
      client.testTrim(); // trim should be a no-op
      expect(client.historyLength, OpenClawClient.kMaxMessages);
    });

    test('history exceeding kMaxMessages is trimmed on next trim call', () {
      // Add enough exchanges to exceed the cap
      addExchanges((OpenClawClient.kMaxMessages + 4) ~/ 2);
      client.testTrim();
      expect(client.historyLength, OpenClawClient.kMaxMessages);
    });

    test('trim keeps exactly kMaxMessages entries after overflow', () {
      addExchanges(20); // 40 messages — 2× the cap
      client.testTrim();
      expect(client.historyLength, OpenClawClient.kMaxMessages);
    });

    // ── Anchor preservation ───────────────────────────────────────────────────

    test('trim preserves first kAnchorMessages entries', () {
      // Seed anchor messages with distinctive content
      client.testAddToHistory({'role': 'user',      'content': 'ANCHOR_USER'});
      client.testAddToHistory({'role': 'assistant', 'content': 'ANCHOR_ASSISTANT'});

      // Pad with enough to trigger a trim
      addExchanges(15); // total: 2 + 30 = 32 > kMaxMessages=20

      client.testTrim();

      // First two should still be the anchors
      expect(client.testHistory[0]['content'], 'ANCHOR_USER');
      expect(client.testHistory[1]['content'], 'ANCHOR_ASSISTANT');
    });

    test('trim drops middle entries, not anchors or recent', () {
      client.testAddToHistory({'role': 'user',      'content': 'ANCHOR_USER'});
      client.testAddToHistory({'role': 'assistant', 'content': 'ANCHOR_ASSISTANT'});

      // Add 15 more exchanges (30 messages) to pad the middle
      addExchanges(15);

      // Add one final distinctive exchange that should survive the trim
      client.testAddToHistory({'role': 'user',      'content': 'LAST_USER'});
      client.testAddToHistory({'role': 'assistant', 'content': 'LAST_ASSISTANT'});

      client.testTrim();

      // Anchors and recents should survive; middle should be gone
      expect(client.testHistory.first['content'], 'ANCHOR_USER');
      expect(client.testHistory.last['content'],  'LAST_ASSISTANT');
      expect(client.historyLength, OpenClawClient.kMaxMessages);

      // Middle entries are gone — none of the padded 'user message N' entries
      // should be in the first few positions (except anchors)
      final midContent = client.testHistory
          .skip(OpenClawClient.kAnchorMessages)
          .take(3)
          .map((m) => m['content'])
          .toList();
      expect(midContent, isNot(contains('user message 0')));
    });

    test('trim is idempotent — calling twice gives same result', () {
      addExchanges(20);
      client.testTrim();
      final after1 = client.historyLength;
      client.testTrim();
      expect(client.historyLength, after1);
    });
  });
}
