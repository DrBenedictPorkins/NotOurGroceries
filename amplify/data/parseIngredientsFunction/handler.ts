import { SSMClient, GetParametersCommand } from '@aws-sdk/client-ssm';
import Anthropic from '@anthropic-ai/sdk';
import type { Schema } from '../resource';

const MODEL = 'claude-haiku-4-5-20251001'; // Fast and cheap for simple text parsing

type Handler = Schema['parseIngredients']['functionHandler'];

interface ParsedIngredient {
  name: string;
  quantity?: string;
  qualifier?: string;
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
  const { rawText, knownTerms, imageData } = event.arguments;

  const isImageMode = !!(imageData && imageData.length > 0);

  console.log('[PARSE] request', JSON.stringify({
    mode: isImageMode ? 'image' : 'text',
    textLength: rawText?.length ?? 0,
    imageDataLength: imageData?.length ?? 0,
    knownTermsCount: knownTerms?.length ?? 0,
  }));

  if (!isImageMode && (!rawText || rawText.trim().length === 0)) {
    console.log('[PARSE] empty input, returning []');
    return [] as unknown as string;
  }

  const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY! });

  const knownTermsSection = knownTerms?.length
    ? `\nKnown product names in our catalog — use these exact terms when they match semantically (e.g. output "Carrot" not "Carrots", "Chicken Breast" not "Chicken Breast Fillet"):\n${knownTerms.join(', ')}\n`
    : '';

  const rules = `Rules:
- Extract only grocery/food items and common household supplies
- For quantities: separate the amount from the item name (e.g., "2 cups flour" → name: "Flour", quantity: "2 cups")
- For qualifiers: extract color, variety, flavor, or type modifiers into a separate "qualifier" field; the name should be the base catalog item
  Examples: "Red Bell Peppers" → name: "Bell Peppers", qualifier: "Red"
            "Beef Stock" → name: "Stock", qualifier: "Beef"
            "Unsalted Butter" → name: "Butter", qualifier: "Unsalted"
            "Chicken Breast" → name: "Chicken Breast" (no qualifier — Breast defines the cut, not a modifier)
- Normalize item names to simple grocery store form (e.g., "all-purpose flour" → name: "Flour", qualifier: "All-Purpose")
- Remove cooking instructions, temperatures, prep notes (e.g., "diced", "chopped", "at room temperature")
- Each unique item should appear only once
- Ignore non-grocery text like recipe titles, step numbers, comments
- Keep names concise but recognizable (Title Case)
- Word grouping: when adjacent words in the input could form a single known catalog term (see list below), prefer the multi-word interpretation and do NOT split it. Example: input "tomato soup" → one item "Tomato Soup" if it appears in the catalog (or is a common dish), not two items "Tomato" + "Soup". This matters especially for voice/dictated input where commas may be missing.
${knownTermsSection}
Return ONLY a JSON array, no markdown, no explanation:
[
  {"name": "Chicken Breast", "quantity": "2 lbs"},
  {"name": "Garlic", "quantity": "3 cloves"},
  {"name": "Bell Peppers", "quantity": "3", "qualifier": "Red"},
  {"name": "Olive Oil"}
]`;

  const messageContent: Anthropic.MessageParam['content'] = isImageMode
    ? [
        {
          type: 'image',
          source: {
            type: 'base64',
            media_type: 'image/jpeg',
            data: imageData!,
          },
        },
        {
          type: 'text',
          text: `Look at this image and extract all grocery/food items visible. This may be a recipe, shopping list, handwritten note, menu, or ingredient list.\n\n${rules}`,
        },
      ]
    : `Parse the following text and extract a clean list of grocery items.\n\n${rules}\n\nInput text:\n${rawText}`;

  const response = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 1024,
    temperature: 0,
    messages: [{ role: 'user', content: messageContent }],
  });

  const textContent = response.content.find((block) => block.type === 'text');
  if (!textContent || textContent.type !== 'text') {
    console.error('[PARSE] no text block in Claude response:', JSON.stringify(response.content));
    return [] as unknown as string;
  }

  console.log('[PARSE] claude raw response:', textContent.text);

  // Extract JSON array from response
  const jsonMatch = textContent.text.match(/\[[\s\S]*\]/);
  if (!jsonMatch) {
    console.error('[PARSE] no JSON array in response:', textContent.text);
    return [] as unknown as string;
  }

  const parsed: ParsedIngredient[] = JSON.parse(jsonMatch[0]);

  // Validate and clean each item
  const cleaned = parsed
    .filter((item) => item.name && item.name.trim().length > 0)
    .map((item) => ({
      name: item.name.trim(),
      ...(item.quantity && item.quantity.trim() ? { quantity: item.quantity.trim() } : {}),
      ...(item.qualifier && item.qualifier.trim() ? { qualifier: item.qualifier.trim() } : {}),
    }));

  console.log('[PARSE] result', JSON.stringify(cleaned));

  return cleaned as unknown as string;
};
