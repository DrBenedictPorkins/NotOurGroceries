import { SSMClient, GetParametersCommand } from '@aws-sdk/client-ssm';
import Anthropic from '@anthropic-ai/sdk';
import type { Schema } from '../resource';

const MODEL = 'claude-haiku-4-5-20251001'; // Fast and cheap for simple text parsing

type Handler = Schema['parseIngredients']['functionHandler'];

interface ParsedIngredient {
  name: string;
  quantity?: string;
}

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
  const { rawText, knownTerms } = event.arguments;

  if (!rawText || rawText.trim().length === 0) {
    return [] as unknown as string;
  }

  const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY! });

  const knownTermsSection = knownTerms?.length
    ? `\nKnown product names in our catalog — use these exact terms when they match semantically (e.g. output "Carrot" not "Carrots", "Chicken Breast" not "Chicken Breast Fillet"):\n${knownTerms.join(', ')}\n`
    : '';

  const prompt = `Parse the following text and extract a clean list of grocery items.

Rules:
- Extract only grocery/food items and common household supplies
- For quantities: separate the amount from the item name (e.g., "2 cups flour" → name: "Flour", quantity: "2 cups")
- Normalize item names to simple grocery store form (e.g., "all-purpose flour" → "Flour", "unsalted butter" → "Butter")
- Remove cooking instructions, temperatures, prep notes (e.g., "diced", "chopped", "at room temperature")
- Each unique item should appear only once
- Ignore non-grocery text like recipe titles, step numbers, comments
- Keep names concise but recognizable (Title Case)
${knownTermsSection}
Input text:
${rawText}

Return ONLY a JSON array, no markdown, no explanation:
[
  {"name": "Chicken Breast", "quantity": "2 lbs"},
  {"name": "Garlic", "quantity": "3 cloves"},
  {"name": "Olive Oil"}
]`;

  const response = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 1024,
    temperature: 0,
    messages: [{ role: 'user', content: prompt }],
  });

  const textContent = response.content.find((block) => block.type === 'text');
  if (!textContent || textContent.type !== 'text') {
    return [] as unknown as string;
  }

  // Extract JSON array from response
  const jsonMatch = textContent.text.match(/\[[\s\S]*\]/);
  if (!jsonMatch) {
    console.error('[PARSE] No JSON array found in response:', textContent.text);
    return [] as unknown as string;
  }

  const parsed: ParsedIngredient[] = JSON.parse(jsonMatch[0]);

  // Validate and clean each item
  const cleaned = parsed
    .filter((item) => item.name && item.name.trim().length > 0)
    .map((item) => ({
      name: item.name.trim(),
      ...(item.quantity && item.quantity.trim() ? { quantity: item.quantity.trim() } : {}),
    }));

  return cleaned as unknown as string;
};
