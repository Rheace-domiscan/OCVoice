# OCVoice Discord Voice Bot

Real-time voice chat with your AI in Discord.

**Pipeline:** You (mic) → Discord voice channel → Deepgram STT → OpenClaw LLM (Claude) → ElevenLabs TTS → Discord voice channel

---

## Setup (5 steps)

### 1. Create a Discord Application

1. Go to <https://discord.com/developers/applications>
2. New Application → name it e.g. **OCVoice**
3. Click **Bot** → Reset Token → copy token
4. Under **Privileged Gateway Intents**, enable:
   - **Server Members Intent** ✅
   - **Voice State Intent** (listed under Bot tab, or just ensure GUILD_VOICE_STATES) ✅
5. Under **OAuth2 → URL Generator**:
   - Scopes: `bot`, `applications.commands`
   - Bot Permissions: `Connect`, `Speak`, `Use Voice Activity`, `Send Messages`, `Read Message History`
6. Copy the generated URL, open it, invite the bot to your server

### 2. Configure .env

```bash
cp .env.example .env
```

Edit `.env` and fill in:
- `DISCORD_BOT_TOKEN` — from step 1
- `DEEPGRAM_API_KEY` — your Deepgram API key
- `ELEVENLABS_API_KEY` — your ElevenLabs key
- `ELEVENLABS_VOICE_ID` — your voice ID (default: Kryto's custom voice)
- `DISCORD_GUILD_ID` — your server ID (already set to your guild)
- `OPENCLAW_GATEWAY_TOKEN` — from OpenClaw config (already in `.env.example`)

### 3. Install dependencies

```bash
npm install
```

### 4. Start the bot

```bash
npm start
```

### 5. Use it

In any text channel in your Discord server:

| Command | Action |
|---------|--------|
| `/join` | Bot joins your current voice channel and starts listening |
| `/leave` | Bot leaves |
| `/reset` | Clear conversation history (start fresh) |

Join a voice channel first, then type `/join` in a text channel.  
Transcripts and replies are echoed to the text channel in real time.

---

## How it works

1. Bot joins your voice channel with `selfDeaf: false` (required to receive audio)
2. Your Discord Opus audio is decoded to PCM16 (48kHz stereo) via prism-media
3. PCM stream is sent to Deepgram WebSocket for real-time STT
4. On `speech_final`, transcript is sent to OpenClaw gateway (localhost:18789) via OpenAI-compatible API
5. Response is synthesised with ElevenLabs TTS
6. MP3 audio is played back in your voice channel

---

## Architecture

```
You (voice)
  ↓ Opus audio
Discord Voice Channel
  ↓ @discordjs/voice receiver
prism-media Opus decoder → PCM16 48kHz stereo
  ↓
Deepgram WebSocket (nova-2)
  ↓ speech_final transcript
OpenClaw Gateway (localhost:18789) → Claude
  ↓ reply text
ElevenLabs TTS (eleven_turbo_v2_5)
  ↓ MP3
Discord AudioPlayer → Voice channel
```
