/**
 * OpenClaw gateway LLM client.
 * Uses the local gateway's OpenAI-compatible /v1/chat/completions endpoint.
 */

const GATEWAY_URL = process.env.OPENCLAW_GATEWAY_URL ?? 'http://localhost:18789';
const GATEWAY_TOKEN = process.env.OPENCLAW_GATEWAY_TOKEN ?? '';
const MAX_HISTORY = 20;

export class LlmClient {
  constructor() {
    this.history = [];
  }

  async chat(userText) {
    this.history.push({ role: 'user', content: userText });

    // Keep history manageable
    if (this.history.length > MAX_HISTORY) {
      this.history = this.history.slice(-MAX_HISTORY);
    }

    const messages = [
      {
        role: 'system',
        content:
          'You are a helpful voice assistant. Keep responses concise and conversational — suitable for spoken audio. Avoid markdown formatting like bullet points or asterisks.',
      },
      ...this.history,
    ];

    const res = await fetch(`${GATEWAY_URL}/v1/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${GATEWAY_TOKEN}`,
      },
      body: JSON.stringify({
        model: 'anthropic/claude-sonnet-4-6',
        messages,
        stream: false,
        max_tokens: 300,
      }),
    });

    if (!res.ok) {
      const body = await res.text();
      throw new Error(`OpenClaw LLM error ${res.status}: ${body}`);
    }

    const data = await res.json();
    const reply = data.choices?.[0]?.message?.content?.trim() ?? '';

    if (reply) {
      this.history.push({ role: 'assistant', content: reply });
    }

    return reply;
  }

  reset() {
    this.history = [];
  }
}
