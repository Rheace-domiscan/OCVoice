# OCVoice — Project Plan

> **Single source of truth for the OCVoice project.**
> Last updated: 2026-02-22

---

## Vision

A downloadable native app that lets anyone run their entire OpenClaw setup using only their voice. No typing required. Works on mobile (screen locked) and desktop.

---

## Goal

Voice in → OpenClaw brain → Voice out.

Near-instant response. ChatGPT voice quality. OpenClaw is the AI, not just OpenAI.

---

## Architecture

```
User speaks
    ↓
[Deepgram Nova-2] — streaming STT, auto-detects end of speech
    ↓
transcript text
    ↓
[OpenClaw Gateway] — the brain
    Memory / Tools / Skills / Agents / Model routing
    Endpoint: https://rheaces-macbook-pro-1.taildb31e4.ts.net
    Auth: Bearer token (stored in device keychain)
    API: OpenAI-compatible /v1/chat/completions
    ↓
response text (streamed)
    ↓
[ElevenLabs] — streaming TTS
    ↓
User hears the response
```

---

## Latency Target

Aiming for **sub-1 second to first audio** — competitive with ChatGPT voice.

| Step | Expected |
|------|---------|
| Deepgram streaming STT | 200–300ms |
| OpenClaw first token | 200–400ms |
| ElevenLabs first audio chunk | 250–300ms |
| **Total to first audio** | **~650ms–1s** |

---

## Platform

**Flutter** — single codebase, builds to all targets:

| Platform | Distribution |
|---------|-------------|
| iOS | App Store |
| Android | Play Store |
| macOS | Direct download / notarised DMG |
| Windows | Direct download / installer |

Key requirement: **background audio support** — app stays active and audible when phone screen is locked.

---

## APIs & Services

| Service | Purpose | Cost |
|---------|---------|------|
| Deepgram Nova-2 | Speech-to-text (streaming) | Free: 200hr/yr |
| OpenClaw Gateway | AI brain (all logic lives here) | Self-hosted on Mac |
| ElevenLabs | Text-to-speech (streaming) | Free: 10k chars/month |
| Tailscale Funnel | Gateway tunnel (permanent public HTTPS URL) | Free |

---

## Gateway Access

| Setting | Value |
|---------|-------|
| Public URL | `https://rheaces-macbook-pro-1.taildb31e4.ts.net` |
| Auth | Bearer token (see secure config — not stored in repo) |
| API format | OpenAI-compatible (`/v1/chat/completions`) |
| Tunnel | Tailscale Funnel (`--bg`, persists across restarts) |

> ⚠️ The gateway token is **never committed to this repo**. It is stored in the app's secure keychain and configured via the app's onboarding screen.

---

## App Structure (planned)

```
OCVoice/
├── PLAN.md                        ← you are here
├── README.md
├── .env.example
├── apps/
│   └── flutter/
│       ├── lib/
│       │   ├── main.dart
│       │   ├── services/
│       │   │   ├── deepgram_stt.dart     # Streaming STT via WebSocket
│       │   │   ├── openclaw_client.dart  # Gateway HTTP client
│       │   │   └── elevenlabs_tts.dart   # Streaming TTS
│       │   ├── audio/
│       │   │   ├── vad.dart              # Voice activity detection
│       │   │   └── player.dart           # Audio output (background-capable)
│       │   ├── config/
│       │   │   └── settings.dart         # Gateway URL + token, stored in keychain
│       │   └── ui/
│       │       ├── voice_screen.dart     # Main screen (connect + status)
│       │       └── settings_screen.dart  # Gateway URL / token / TTS config
│       └── pubspec.yaml
└── docs/
    └── onboarding.md                     # How to set up gateway access
```

---

## Build Order

### Sprint 1 — Core Voice Loop (current)

- [ ] Repo setup ✅
- [ ] Flutter project scaffold (all 4 platform targets)
- [ ] Deepgram streaming STT integration
- [ ] OpenClaw Gateway client (streaming chat completions)
- [ ] ElevenLabs streaming TTS integration
- [ ] Voice Activity Detection (auto end-of-speech)
- [ ] Background audio session (iOS/Android locked screen)
- [ ] Basic UI: connect button + status indicator

**No text input in Sprint 1.**

### Sprint 2 — Polish & Reliability

- [ ] Interruption handling (user speaks while assistant talks)
- [ ] Reconnection logic (network drops)
- [ ] Better VAD tuning
- [ ] Onboarding flow (gateway URL + token setup)
- [ ] App icon + basic branding

### Sprint 3 — Distribution

- [ ] iOS App Store submission
- [ ] Android Play Store submission
- [ ] macOS notarised DMG
- [ ] Windows installer

### Later

- [ ] Text input fallback
- [ ] Conversation history display
- [ ] Multiple gateway profiles
- [ ] Wake word ("Hey OpenClaw")
- [ ] Offline / local model fallback

---

## Design Principles

- **Voice-first**: every interaction is designed for voice, not adapted from text
- **OpenClaw as the brain**: all intelligence, memory, and tools live in OpenClaw — the app is a thin voice interface
- **Low latency above all**: architectural decisions should prioritise time-to-first-audio
- **Simple UI**: nothing unnecessary on screen — a status indicator and a connect control is enough
- **Secure by default**: gateway token never leaves device storage, never in code

---

## Non-Negotiable Product Requirements

- **No OpenAI API key required in OCVoice**
  - OCVoice must run without storing, requesting, or requiring an OpenAI key.
  - Voice stack is: Deepgram (STT) + OpenClaw Gateway (LLM/tools/memory) + ElevenLabs (TTS).
- **ChatGPT-level voice UX target**
  - Continuous conversation feel
  - Fast turn-taking
  - **Automatic interruption (barge-in) enabled by default**
  - Minimal user friction

## Key Decisions Made

| Decision | Choice | Reason |
|----------|--------|--------|
| App framework | Flutter | Best cross-platform audio + background support |
| STT provider | Deepgram Nova-2 | Lowest latency streaming STT |
| LLM / brain | OpenClaw Gateway | Full memory/tools/skills, OpenAI-compatible |
| TTS provider | ElevenLabs | Best streaming quality for mobile, cloud (no latency overhead from Mac) |
| Gateway tunnel | Tailscale Funnel | Permanent URL, free, built-in to OpenClaw, secure |
| Text input | Not in Sprint 1 | Voice-first focus |

---

## Open Questions

- App name: **OCVoice** (working title — finalise before App Store)
- ElevenLabs voice selection (to be decided during development)
- Whether to support multiple OpenClaw gateway profiles per user
