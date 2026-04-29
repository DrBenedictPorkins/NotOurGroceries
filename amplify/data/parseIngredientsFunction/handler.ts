import Anthropic from '@anthropic-ai/sdk';
import type { Schema } from '../resource';

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY!;
const MODEL = 'claude-haiku-4-5-20251001'; // Fast and cheap for simple text parsing

type Handler = Schema['parseIngredients']['functionHandler'];

interface ParsedIngredient {
  name: string;
  quantity?: string;
}

export const handler: Handler = async (event) => {
  const { rawText } = event.arguments;

  if (!rawText || rawText.trim().length === 0) {
    return JSON.stringify([]);
  }

  const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY });

  const prompt = `Parse the following text and extract a clean list of grocery items.

Rules:
- Extract only grocery/food items and common household supplies
- For quantities: separate the amount from the item name (e.g., "2 cups flour" → name: "Flour", quantity: "2 cups")
- Normalize item names to simple grocery store form (e.g., "all-purpose flour" → "Flour", "unsalted butter" → "Butter")
- Remove cooking instructions, temperatures, prep notes (e.g., "diced", "chopped", "at room temperature")
- Each unique item should appear only once
- Ignore non-grocery text like recipe titles, step numbers, comments
- Keep names concise but recognizable (Title Case)

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
    return JSON.stringify([]);
  }

  // Extract JSON array from response
  const jsonMatch = textContent.text.match(/\[[\s\S]*\]/);
  if (!jsonMatch) {
    console.error('[PARSE] No JSON array found in response:', textContent.text);
    return JSON.stringify([]);
  }

  const parsed: ParsedIngredient[] = JSON.parse(jsonMatch[0]);

  // Validate and clean each item
  const cleaned = parsed
    .filter((item) => item.name && item.name.trim().length > 0)
    .map((item) => ({
      name: item.name.trim(),
      ...(item.quantity && item.quantity.trim() ? { quantity: item.quantity.trim() } : {}),
    }));

  return JSON.stringify(cleaned);
};
