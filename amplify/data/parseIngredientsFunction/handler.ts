import { SSMClient, GetParametersCommand } from '@aws-sdk/client-ssm';
import Anthropic from '@anthropic-ai/sdk';
import type { Schema } from '../resource';

const MODEL = 'claude-haiku-4-5-20251001'; // Fast and cheap for simple text parsing

type Handler = Schema['parseIngredients']['functionHandler'];

interface ParsedIngredient {
  name: string;
  quantity?: string;
  qualifier?: string;
  /** The speaker's own words, when the parsed name differs meaningfully from them. */
  heardAs?: string;
  /** Set when the transcript alone could not resolve this item. */
  needsInput?: boolean;
  /** Candidate names, best first, when the words support more than one product. */
  alternatives?: string[];
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
- Do NOT split a compound that is its own distinct product just because part of it looks like a modifier. If you would buy it off the shelf under that whole name, keep the whole name:
    "Iced Tea"     → name: "Iced Tea"     (NOT Tea + qualifier Iced — a different product from tea)
    "Sour Cream"   → name: "Sour Cream"   (NOT Cream + qualifier Sour)
    "Heavy Cream"  → name: "Heavy Cream"  (NOT Cream + qualifier Heavy)
    "Cream Cheese" → name: "Cream Cheese" (NOT Cheese + qualifier Cream)
    "Ground Beef"  → name: "Ground Beef"  (NOT Beef + qualifier Ground)
  Ask yourself: would substituting the base item satisfy the shopper? If no, it is one item, not an item plus a qualifier.
- Do NOT generalise a specific product up to its category. The shopper asked for a specific thing and will not find it otherwise:
    "macaroni" → "Macaroni" (NOT "Pasta"),  "cheddar" → "Cheddar" (NOT "Cheese"),  "baguette" → "Baguette" (NOT "Bread")
- Remove cooking instructions, temperatures, prep notes (e.g., "diced", "chopped", "at room temperature")
- Each unique item should appear only once
- Ignore non-grocery text like recipe titles, step numbers, comments
- Keep names concise but recognizable (Title Case)
- Word grouping: when adjacent words in the input could form a single known catalog term (see list below), prefer the multi-word interpretation and do NOT split it. Example: input "tomato soup" → one item "Tomato Soup" if it appears in the catalog (or is a common dish), not two items "Tomato" + "Soup". This matters especially for voice/dictated input where commas may be missing.

Dictated speech: this input is often a transcript of someone talking, so treat it as one side of a conversation rather than a written list.
- Strip conversational framing entirely: "ok", "so", "um", "let's see", "I need", "I want you to add", "we'll get some", "don't forget", "oh and". These are never items.
- Honour self-corrections — the LAST thing said about an item wins:
    "milk, actually make that two gallons" → one item, Milk, quantity "2 gallons"
    "get cheddar, no wait, mozzarella"     → one item, Mozzarella (NOT cheddar)
    "apples, the green ones"               → name: "Apples", qualifier: "Green"
- Honour retractions — if the speaker takes an item back, omit it completely:
    "add eggs... actually skip the eggs, we have plenty" → no Eggs item at all
    Watch for: "never mind", "forget the", "skip", "we already have", "cancel that", "not the".
- A qualifier or quantity mentioned after the item still belongs to it, even sentences later, as long as the speaker is clearly still referring to it.
- Transcription is imperfect. Repair obvious mis-hearings into the sensible grocery term when confident: "macaronis" → "Macaroni", "whole flour" → "Whole Wheat Flour", "do a orange juice" → "Orange Juice". Do not invent items you are not confident about.
- Speakers repeat themselves when thinking aloud; collapse duplicates into a single item carrying the richest quantity/qualifier mentioned.
${knownTermsSection}
Flagging what you are unsure about — this is as important as the extraction itself.
The user sees confident items in one list and everything else in a "needs your input"
list underneath. Being silently wrong is far worse than asking, but asking about
everything makes the feature useless. So flag ONLY genuine uncertainty:
- "heardAs": include the speaker's own words whenever your output differs meaningfully from what they said (a repaired mis-hearing, a normalisation, a guessed quantity). Omit it when you used their words as-is.
- "needsInput": true when you could not resolve it from the transcript alone. Two cases:
    (a) you repaired a probable mis-hearing and could be wrong — "macaronis" → Macaroni
    (b) the words genuinely support more than one product and nothing decides between them — "tea" could be Tea or Iced Tea
  Do NOT set it merely because an item is absent from the catalog. Unusual is not ambiguous.
- "alternatives": for case (b), 2-4 candidate names, BEST FIRST. Prefer names from the catalog list below, because those are things this household actually buys — if one candidate is in the catalog and another is not, the catalog one goes first. Include your chosen "name" as one of the alternatives.

Return ONLY a JSON array, no markdown, no explanation:
[
  {"name": "Chicken Breast", "quantity": "2 lbs"},
  {"name": "Garlic", "quantity": "3 cloves"},
  {"name": "Bell Peppers", "quantity": "3", "qualifier": "Red"},
  {"name": "Macaroni", "heardAs": "some macaronis", "needsInput": true},
  {"name": "Iced Tea", "heardAs": "tea", "needsInput": true, "alternatives": ["Iced Tea", "Tea"]},
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
      ...(item.heardAs && item.heardAs.trim() ? { heardAs: item.heardAs.trim() } : {}),
      ...(item.needsInput === true ? { needsInput: true } : {}),
      ...(Array.isArray(item.alternatives) && item.alternatives.length > 1
        ? { alternatives: item.alternatives.filter((a: unknown) => typeof a === 'string' && a.trim()).slice(0, 4) }
        : {}),
    }));

  console.log('[PARSE] result', JSON.stringify(cleaned));

  return cleaned as unknown as string;
};
