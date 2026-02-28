/**
 * ElevenLabs TTS — returns MP3 buffer for a given text string.
 */

const ELEVENLABS_API_KEY = process.env.ELEVENLABS_API_KEY ?? '';
const ELEVENLABS_VOICE_ID = process.env.ELEVENLABS_VOICE_ID ?? 'tnSpp4vdxKPjI9w0GnoV';
const TTS_URL = `https://api.elevenlabs.io/v1/text-to-speech/${ELEVENLABS_VOICE_ID}/stream`;

export async function synthesise(text) {
  if (!text?.trim()) return null;

  const res = await fetch(TTS_URL, {
    method: 'POST',
    headers: {
      'xi-api-key': ELEVENLABS_API_KEY,
      'Content-Type': 'application/json',
      Accept: 'audio/mpeg',
    },
    body: JSON.stringify({
      text,
      model_id: 'eleven_turbo_v2_5',
      voice_settings: {
        stability: 0.5,
        similarity_boost: 0.75,
        style: 0.0,
        use_speaker_boost: true,
      },
      output_format: 'mp3_44100_128',
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`ElevenLabs TTS error ${res.status}: ${body}`);
  }

  const arrayBuf = await res.arrayBuffer();
  return Buffer.from(arrayBuf);
}
