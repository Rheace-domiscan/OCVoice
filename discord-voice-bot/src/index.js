/**
 * OCVoice Discord voice bot
 *
 * Commands:
 *   /join   — bot joins your current voice channel and starts listening to you
 *   /leave  — bot leaves, session ends
 *   /reset  — clear conversation history (fresh context)
 *
 * Setup:
 *   1. Copy .env.example → .env, fill in values
 *   2. npm start
 *   3. Invite bot with scopes: bot + applications.commands
 *      Permissions: Connect, Speak, Use Voice Activity, Send Messages, Read Message History
 */

import 'dotenv/config';
import {
  Client,
  GatewayIntentBits,
  Partials,
  REST,
  Routes,
  SlashCommandBuilder,
  Collection,
} from 'discord.js';
import {
  joinVoiceChannel,
  VoiceConnectionStatus,
  entersState,
} from '@discordjs/voice';
import { VoicePipeline } from './pipeline.js';

// ── Config ─────────────────────────────────────────────────────────────────
const BOT_TOKEN = process.env.DISCORD_BOT_TOKEN;
const GUILD_ID = process.env.DISCORD_GUILD_ID;

if (!BOT_TOKEN) {
  console.error('❌ DISCORD_BOT_TOKEN is not set in .env');
  process.exit(1);
}
if (!process.env.DEEPGRAM_API_KEY) {
  console.error('❌ DEEPGRAM_API_KEY is not set in .env');
  process.exit(1);
}
if (!process.env.ELEVENLABS_API_KEY) {
  console.error('❌ ELEVENLABS_API_KEY is not set in .env');
  process.exit(1);
}

// ── Slash command definitions ───────────────────────────────────────────────
const commands = [
  new SlashCommandBuilder()
    .setName('join')
    .setDescription('Bot joins your voice channel and starts listening')
    .toJSON(),
  new SlashCommandBuilder()
    .setName('leave')
    .setDescription('Bot leaves the voice channel')
    .toJSON(),
  new SlashCommandBuilder()
    .setName('reset')
    .setDescription('Clear conversation history — start fresh context')
    .toJSON(),
];

// ── Register commands ───────────────────────────────────────────────────────
async function registerCommands(clientId) {
  const rest = new REST({ version: '10' }).setToken(BOT_TOKEN);
  console.log('[commands] registering slash commands…');
  await rest.put(Routes.applicationGuildCommands(clientId, GUILD_ID), {
    body: commands,
  });
  console.log('[commands] ✅ registered');
}

// ── Bot client ──────────────────────────────────────────────────────────────
const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildVoiceStates,
    GatewayIntentBits.GuildMessages,
  ],
  partials: [Partials.Channel],
});

// Active pipelines keyed by guildId
const pipelines = new Collection();

client.once('ready', async (c) => {
  console.log(`\n✅ Logged in as ${c.user.tag}`);
  await registerCommands(c.user.id);
  console.log(`🎙️  OCVoice Discord bot is ready — type /join in a server channel\n`);
});

client.on('interactionCreate', async (interaction) => {
  if (!interaction.isChatInputCommand()) return;
  if (!GUILD_ID || interaction.guildId !== GUILD_ID) return;

  const { commandName, member, guild, channel } = interaction;

  // ── /join ─────────────────────────────────────────────────────────────────
  if (commandName === 'join') {
    const voiceChannel = member?.voice?.channel;
    if (!voiceChannel) {
      await interaction.reply({
        content: '⚠️ You need to be in a voice channel first.',
        ephemeral: true,
      });
      return;
    }

    // Tear down any existing session
    const existing = pipelines.get(guild.id);
    if (existing) {
      existing.destroy();
      pipelines.delete(guild.id);
    }

    await interaction.reply({
      content: `🎙️ Joining **${voiceChannel.name}** — I'm listening to you now. Talk naturally; I'll respond when you pause.`,
    });

    try {
      const connection = joinVoiceChannel({
        channelId: voiceChannel.id,
        guildId: guild.id,
        adapterCreator: guild.voiceAdapterCreator,
        selfDeaf: false, // must be false to receive audio
        selfMute: false,
      });

      await entersState(connection, VoiceConnectionStatus.Ready, 15_000);
      console.log(`[voice] connected to "${voiceChannel.name}"`);

      const pipeline = new VoicePipeline(
        connection,
        channel, // text channel for transcript echo
        member.id, // listen to this user
      );
      pipelines.set(guild.id, pipeline);

    } catch (err) {
      console.error('[voice] failed to connect:', err.message);
      await channel.send(`❌ Couldn't join voice: ${err.message}`);
    }
    return;
  }

  // ── /leave ────────────────────────────────────────────────────────────────
  if (commandName === 'leave') {
    const pipeline = pipelines.get(guild.id);
    if (!pipeline) {
      await interaction.reply({ content: "I'm not in a voice channel.", ephemeral: true });
      return;
    }
    pipeline.destroy();
    pipelines.delete(guild.id);
    await interaction.reply('👋 Left the voice channel. Session ended.');
    return;
  }

  // ── /reset ────────────────────────────────────────────────────────────────
  if (commandName === 'reset') {
    const pipeline = pipelines.get(guild.id);
    if (pipeline) {
      pipeline.resetHistory();
      await interaction.reply('🔄 Conversation history cleared. Fresh start!');
    } else {
      await interaction.reply({ content: "I'm not in a voice channel.", ephemeral: true });
    }
    return;
  }
});

// ── Start ───────────────────────────────────────────────────────────────────
client.login(BOT_TOKEN);
