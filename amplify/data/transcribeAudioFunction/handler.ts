import { SSMClient, GetParametersCommand } from '@aws-sdk/client-ssm';
import type { Schema } from '../resource';
import { requireHousehold } from '../requireHousehold';
import { logEvent, logWarning, logFailure } from '../telemetry';

type Handler = Schema['transcribeAudio']['functionHandler'];

/**
 * `whisper-1` was trained heavily on YouTube captions, so on trailing silence it
 * completes with caption boilerplate — "Thank you for watching" turning up at
 * the end of a shopping list, reported from real use. `gpt-4o-mini-transcribe`
 * uses the same endpoint, costs less, and does this far less.
 */
const MODEL = 'gpt-4o-mini-transcribe';

/**
 * Caption boilerplate to strip off the end.
 *
 * A better model lowers the odds; it does not make them zero, and this costs
 * nothing. Only matched at the very end of the transcript and only as a whole
 * line or sentence — somebody dictating "thanks" mid-list keeps their word.
 */
const HALLUCINATED_TAILS = [
  'thank you for watching',
  'thanks for watching',
  'thank you for watching!',
  'thanks for watching!',
  'thank you.',
  'thank you',
  'bye',
  'bye.',
  'please subscribe',
  'subscribe to my channel',
  'see you next time',
  'see you in the next video',
];

export function stripHallucinatedTail(text: string): string {
  let out = text.trim();

  // Repeatedly, because Whisper sometimes stacks two of them.
  for (let pass = 0; pass < 3; pass++) {
    const lower = out.toLowerCase();
    const hit = HALLUCINATED_TAILS.find((phrase) => {
      if (!lower.endsWith(phrase)) return false;
      // Must start at a word boundary, or "goodbye" loses its ending. Testing
      // the raw text rather than a trimmed copy — trimming first ate the very
      // newline that marks the boundary in "milk\neggs\nThanks for watching".
      const before = out.slice(0, out.length - phrase.length);
      return before === '' || /\s$/.test(before) || /[.!?,]$/.test(before.trimEnd());
    });
    if (!hit) break;

    const trimmed = out.slice(0, out.length - hit.length).trimEnd().replace(/[.,!?]+$/, '').trimEnd();
    // The matched phrase is model boilerplate, not speech, so it is safe to
    // name — it is how we tell which hallucination is still getting through.
    logWarning('ai.transcribe.tailStripped', { phrase: hit });
    out = trimmed;
  }

  return out.trim();
}

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
  requireHousehold(event);
  await resolveAmplifySecrets();
  const { audioData } = event.arguments;

  if (!audioData || audioData.length === 0) {
    logEvent('ai.transcribe', { outcome: 'empty_audio', bytes: 0, chars: 0, ms: 0 });
    return '';
  }

  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    logFailure('ai.transcribe', new Error('missing OPENAI_API_KEY'), { outcome: 'unconfigured' });
    throw new Error('Transcription service is not configured.');
  }

  const buffer = Buffer.from(audioData, 'base64');


  // Multipart body assembly (no SDK dependency)
  const boundary = `----nog-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const parts: Buffer[] = [];
  const push = (s: string) => parts.push(Buffer.from(s, 'utf8'));

  push(`--${boundary}\r\n`);
  push(`Content-Disposition: form-data; name="model"\r\n\r\n`);
  push(`${MODEL}\r\n`);

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
    logFailure('ai.transcribe', new Error(`Whisper API error: ${response.status}`), {
      outcome: 'upstream_error', status: response.status, bytes: buffer.byteLength, ms: elapsedMs,
    });
    throw new Error(`Whisper API error: ${response.status}`);
  }

  const raw = (await response.text()).trim();
  const transcript = stripHallucinatedTail(raw);
  logEvent('ai.transcribe', {
    outcome: 'ok', model: MODEL, bytes: buffer.byteLength,
    chars: transcript.length, strippedChars: raw.length - transcript.length, ms: elapsedMs,
  });

  return transcript;
};
