import { SSMClient, GetParametersCommand } from '@aws-sdk/client-ssm';
import Anthropic from '@anthropic-ai/sdk';
import {
  MODEL,
  MAX_INPUT_CHARS,
  buildRules,
  buildMessageContent,
  cleanItems,
  type ParsedIngredient,
} from './prompt';
import type { Schema } from '../resource';
import { requireHousehold } from '../requireHousehold';
import { logEvent, logWarning, logFailure, tokenUsage } from '../telemetry';


type Handler = Schema['parseIngredients']['functionHandler'];


// Amplify stores secrets in SSM and resolves them via a wrapper at build time.
// When deploying manually we must resolve them ourselves.
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
  const { rawText, knownTerms, imageData } = event.arguments;

  const isImageMode = !!(imageData && imageData.length > 0);

  const startedAt = Date.now();
  const mode = isImageMode ? 'image' : 'text';
  const shape = {
    mode,
    textLength: rawText?.length ?? 0,
    imageBytes: imageData?.length ?? 0,
    knownTermsCount: knownTerms?.length ?? 0,
  };

  // Hard limits enforced in code, not by asking the model nicely. This endpoint
  // accepts arbitrary text from any authenticated caller, so it is an LLM proxy
  // unless something bounds it. A spoken grocery list is a few hundred characters;
  // anything vastly larger is not one.
  if (!isImageMode && rawText && rawText.length > MAX_INPUT_CHARS) {
    logWarning('ai.parse.truncated', { from: rawText.length, to: MAX_INPUT_CHARS });
  }

  if (!isImageMode && (!rawText || rawText.trim().length === 0)) {
    logEvent('ai.parse', { ...shape, outcome: 'empty_input', itemCount: 0, ms: Date.now() - startedAt });
    return [] as unknown as string;
  }

  const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY! });

  const system: Anthropic.TextBlockParam[] = [
    {
      type: 'text',
      text: buildRules(knownTerms),
      cache_control: { type: 'ephemeral' },
    },
  ];

  const response = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 1024,
    temperature: 0,
    system,
    messages: [{ role: 'user', content: buildMessageContent({ rawText, imageData }) }],
  });

  // If cacheRead stays 0 across repeated parses, something volatile crept into
  // the prefix — check knownTerms ordering first.
  const usage = tokenUsage(response.usage);

  const textContent = response.content.find((block) => block.type === 'text');
  if (!textContent || textContent.type !== 'text') {
    logFailure('ai.parse', new Error('no text block in response'), {
      ...shape, ...usage, blockTypes: response.content.map((b) => b.type), ms: Date.now() - startedAt,
    });
    return [] as unknown as string;
  }

  const jsonMatch = textContent.text.match(/\[[\s\S]*\]/);
  if (!jsonMatch) {
    // The response text is deliberately not logged: on this path it is a
    // refusal or a stray sentence, but on the happy path it is the user's list,
    // and one log statement cannot be trusted to know which.
    logFailure('ai.parse', new Error('no JSON array in response'), {
      ...shape, ...usage, responseChars: textContent.text.length, ms: Date.now() - startedAt,
    });
    return [] as unknown as string;
  }

  const parsed: ParsedIngredient[] = JSON.parse(jsonMatch[0]);
  const cleaned = cleanItems(parsed);

  // Enforce the item cap in code as well; the prompt asks for it, this guarantees it.
  const capped = cleaned.slice(0, 60);
  if (capped.length < cleaned.length) {
    logWarning('ai.parse.capped', { from: cleaned.length, to: capped.length });
  }

  logEvent('ai.parse', {
    ...shape, ...usage, outcome: 'ok', itemCount: capped.length, ms: Date.now() - startedAt,
  });

  return capped as unknown as string;
};
