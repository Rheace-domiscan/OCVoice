/**
 * Voice pipeline: Discord Opus audio → Deepgram STT → OpenClaw LLM → ElevenLabs TTS → Discord playback
 */

import { Readable } from 'node:stream';
import { createClient, LiveTranscriptionEvents } from '@deepgram/sdk';
import {
  createAudioResource,
  createAudioPlayer,
  AudioPlayerStatus,
  StreamType,
  EndBehaviorType,
  VoiceConnectionStatus,
  entersState,
} from '@discordjs/voice';
import prism from 'prism-media';
import { LlmClient } from './llm.js';
import { synthesise } from './tts.js';

const DEEPGRAM_API_KEY = process.env.DEEPGRAM_API_KEY ?? '';

export class VoicePipeline {
  /**
   * @param {import('@discordjs/voice').VoiceConnection} connection
   * @param {import('discord.js').TextChannel} replyChannel  Text channel for status messages
   * @param {string} listenUserId  Discord user id to listen to
   */
  constructor(connection, replyChannel, listenUserId) {
    this.connection = connection;
    this.replyChannel = replyChannel;
    this.listenUserId = listenUserId;
    this.llm = new LlmClient();
    this.player = createAudioPlayer();
    this.connection.subscribe(this.player);
    this._processing = false;
    this._dgConnection = null;
    this._opusStream = null;
    this._decoder = null;

    this.player.on(AudioPlayerStatus.Idle, () => {
      this._processing = false;
      this._startListening();
    });

    this.player.on('error', (err) => {
      console.error('[player] error:', err.message);
      this._processing = false;
      this._startListening();
    });

    this.connection.on(VoiceConnectionStatus.Disconnected, async () => {
      try {
        await Promise.race([
          entersState(this.connection, VoiceConnectionStatus.Signalling, 5_000),
          entersState(this.connection, VoiceConnectionStatus.Connecting, 5_000),
        ]);
      } catch {
        this.destroy();
      }
    });

    this._startListening();
  }

  _startListening() {
    if (this._processing) return;

    // Clean up previous streams
    this._cleanup();

    const dg = createClient(DEEPGRAM_API_KEY);
    this._dgConnection = dg.listen.live({
      model: 'nova-2',
      encoding: 'linear16',
      sample_rate: 48000,
      channels: 2,
      interim_results: true,
      endpointing: 500,
      utterance_end_ms: 1500,
      vad_events: true,
    });

    this._dgConnection.on(LiveTranscriptionEvents.Open, () => {
      console.log('[deepgram] connection open, subscribing to voice…');

      // Subscribe to the target user's audio
      this._opusStream = this.connection.receiver.subscribe(this.listenUserId, {
        end: { behavior: EndBehaviorType.Manual },
      });

      // Decode Opus → PCM16 stereo 48kHz
      this._decoder = new prism.opus.Decoder({
        frameSize: 960,
        channels: 2,
        rate: 48000,
      });

      this._opusStream.pipe(this._decoder);

      this._decoder.on('data', (chunk) => {
        if (this._dgConnection?.getReadyState() === 1) {
          this._dgConnection.send(chunk);
        }
      });

      this._decoder.on('error', (e) => console.error('[decoder] error:', e.message));
    });

    this._dgConnection.on(LiveTranscriptionEvents.Transcript, (data) => {
      const alt = data?.channel?.alternatives?.[0];
      const transcript = alt?.transcript?.trim() ?? '';
      const isFinal = data?.is_final ?? false;
      const speechFinal = data?.speech_final ?? false;

      if (transcript && !isFinal) {
        process.stdout.write(`\r[partial] ${transcript}   `);
      }

      if (speechFinal && transcript) {
        console.log(`\n[final] "${transcript}"`);
        this._handleTurn(transcript);
      }
    });

    this._dgConnection.on(LiveTranscriptionEvents.UtteranceEnd, () => {
      // fallback if speech_final never fires
    });

    this._dgConnection.on(LiveTranscriptionEvents.Error, (err) => {
      console.error('[deepgram] error:', err);
    });

    this._dgConnection.on(LiveTranscriptionEvents.Close, () => {
      console.log('[deepgram] connection closed');
    });
  }

  async _handleTurn(userText) {
    if (this._processing) return;
    if (!userText || userText.length < 2) return;

    this._processing = true;
    this._cleanup(); // stop listening while we speak

    try {
      await this.replyChannel.send(`🎙️ **${userText}**`).catch(() => {});

      console.log('[llm] sending to OpenClaw…');
      const reply = await this.llm.chat(userText);

      if (!reply) {
        console.warn('[llm] empty response');
        this._processing = false;
        this._startListening();
        return;
      }

      console.log(`[llm] reply: "${reply}"`);
      await this.replyChannel.send(`🤖 ${reply}`).catch(() => {});

      console.log('[tts] synthesising…');
      const mp3 = await synthesise(reply);
      if (!mp3) {
        this._processing = false;
        this._startListening();
        return;
      }

      const readable = Readable.from(mp3);
      const resource = createAudioResource(readable, {
        inputType: StreamType.Arbitrary,
      });

      this.player.play(resource);
      // AudioPlayerStatus.Idle listener will re-start listening after playback ends
    } catch (err) {
      console.error('[pipeline] error:', err.message);
      await this.replyChannel
        .send(`⚠️ Pipeline error: ${err.message.slice(0, 120)}`)
        .catch(() => {});
      this._processing = false;
      this._startListening();
    }
  }

  _cleanup() {
    if (this._decoder) {
      try {
        this._opusStream?.unpipe(this._decoder);
        this._decoder.destroy();
      } catch (_) {}
      this._decoder = null;
    }
    if (this._opusStream) {
      try {
        this._opusStream.destroy();
      } catch (_) {}
      this._opusStream = null;
    }
    if (this._dgConnection) {
      try {
        this._dgConnection.requestClose();
      } catch (_) {}
      this._dgConnection = null;
    }
  }

  destroy() {
    this._cleanup();
    try {
      this.player.stop(true);
    } catch (_) {}
    try {
      this.connection.destroy();
    } catch (_) {}
  }

  resetHistory() {
    this.llm.reset();
  }
}
