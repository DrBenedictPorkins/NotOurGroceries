import { SSMClient, GetParametersCommand } from '@aws-sdk/client-ssm';
import type { Schema } from '../resource';

type Handler = Schema['transcribeAudio']['functionHandler'];

let secretsResolved = false;
async function resolveAmplifySecrets(): Promise<void> {
  if (secretsResolved) return;
  secretsResolved = true;
  const raw = process.env.AMPLIFY_SSM_ENV_CONFIG;
  if (!raw) return;
  const config: Record<string, { path: string; sharedPath: string }> = JSON.parse(raw);
  const ssm = new SSMClient({ region: process.env.AWS_REGION ?? 'us-east-1' });
  for (const [envVar, { path, sharedPath }] of Object.entries(config)) {
    const { Parameters } = await ssm.send(new GetParametersCommand({ Names: [path, sharedPath], WithDecryption: true }));
    const found = Parameters?.find((p) => p.Value);
    if (found?.Value) process.env[envVar] = found.Value;
  }
}

export const handler: Handler = async (event) => {
  await resolveAmplifySecrets();
  const { audioData } = event.arguments;

  if (!audioData || audioData.length === 0) {
    console.log('[TRANSCRIBE] empty audio, returning empty string');
    return '';
  }

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    console.error('[TRANSCRIBE] missing OPENAI_API_KEY');
    throw new Error('Transcription service is not configured.');
  }

  const buffer = Buffer.from(audioData, 'base64');
  console.log('[TRANSCRIBE] request', JSON.stringify({ bytes: buffer.byteLength }));

  // Multipart body assembly (no SDK dependency)
  const boundary = `----nog-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const parts: Buffer[] = [];
  const push = (s: string) => parts.push(Buffer.from(s, 'utf8'));

  push(`--${boundary}\r\n`);
  push(`Content-Disposition: form-data; name="model"\r\n\r\n`);
  push(`whisper-1\r\n`);

  push(`--${boundary}\r\n`);
  push(`Content-Disposition: form-data; name="response_format"\r\n\r\n`);
  push(`text\r\n`);

  push(`--${boundary}\r\n`);
  push(`Content-Disposition: form-data; name="file"; filename="audio.m4a"\r\n`);
  push(`Content-Type: audio/m4a\r\n\r\n`);
  parts.push(buffer);
  push(`\r\n--${boundary}--\r\n`);

  const body = Buffer.concat(parts);

  const started = Date.now();
  const response = await fetch('https://api.openai.com/v1/audio/transcriptions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': `multipart/form-data; boundary=${boundary}`,
    },
    body,
  });
  const elapsedMs = Date.now() - started;

  if (!response.ok) {
    const errText = await response.text();
    console.error('[TRANSCRIBE] whisper error', response.status, errText);
    throw new Error(`Whisper API error: ${response.status}`);
  }

  const transcript = (await response.text()).trim();
  console.log('[TRANSCRIBE] success', JSON.stringify({ elapsedMs, chars: transcript.length }));

  return transcript;
};
