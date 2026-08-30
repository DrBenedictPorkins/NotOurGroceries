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
  await resolveAmplifySecrets();
  const { rawText, knownTerms, imageData } = event.arguments;

  const isImageMode = !!(imageData && imageData.length > 0);

  console.log('[PARSE] request', JSON.stringify({
    mode: isImageMode ? 'image' : 'text',
    textLength: rawText?.length ?? 0,
    imageDataLength: imageData?.length ?? 0,
    knownTermsCount: knownTerms?.length ?? 0,
  }));

  // Hard limits enforced in code, not by asking the model nicely. This endpoint
  // accepts arbitrary text from any authenticated caller, so it is an LLM proxy
  // unless something bounds it. A spoken grocery list is a few hundred characters;
  // anything vastly larger is not one.
  if (!isImageMode && rawText && rawText.length > MAX_INPUT_CHARS) {
    console.warn('[PARSE] input truncated', { from: rawText.length, to: MAX_INPUT_CHARS });
  }

  if (!isImageMode && (!rawText || rawText.trim().length === 0)) {
    console.log('[PARSE] empty input, returning []');
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

  // If this logs 0 across repeated parses, something volatile crept into the
  // prefix — check knownTerms ordering first.
  console.log('[PARSE] cache', JSON.stringify({
    created: response.usage.cache_creation_input_tokens,
    read: response.usage.cache_read_input_tokens,
    uncached: response.usage.input_tokens,
  }));

  const textContent = response.content.find((block) => block.type === 'text');
  if (!textContent || textContent.type !== 'text') {
    console.error('[PARSE] no text block in Claude response:', JSON.stringify(response.content));
    return [] as unknown as string;
  }

  console.log('[PARSE] claude raw response:', textContent.text);

  const jsonMatch = textContent.text.match(/\[[\s\S]*\]/);
  if (!jsonMatch) {
    console.error('[PARSE] no JSON array in response:', textContent.text);
    return [] as unknown as string;
  }

  const parsed: ParsedIngredient[] = JSON.parse(jsonMatch[0]);
  const cleaned = cleanItems(parsed);

  // Enforce the item cap in code as well; the prompt asks for it, this guarantees it.
  const capped = cleaned.slice(0, 60);
  if (capped.length < cleaned.length) {
    console.warn('[PARSE] result capped', { from: cleaned.length, to: capped.length });
  }

  console.log('[PARSE] result', JSON.stringify(capped));

  return capped as unknown as string;
};
