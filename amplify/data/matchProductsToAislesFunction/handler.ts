import Anthropic from '@anthropic-ai/sdk';
import type { AppSyncResolverEvent } from 'aws-lambda';

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY!;

interface AisleEntry {
  productName: string;
  aisle: string;
}

interface ProductInput {
  id: string;
  name: string;
  normalizedName: string;
}

interface HandlerArguments {
  aisleEntries: AisleEntry[] | string; // Can be JSON string from AWSJSON
  products: ProductInput[] | string;   // Can be JSON string from AWSJSON
}

interface ProductMapping {
  productId: string;
  aisleId: string;
  confidence: number;
  reasoning: string;
}

interface MatchResult {
  success: boolean;
  mappings: ProductMapping[];
  stats: {
    total: number;
    highConfidence: number;
    mediumConfidence: number;
    lowConfidence: number;
  };
  error?: string;
}

export const handler = async (
  event: AppSyncResolverEvent<HandlerArguments>
): Promise<MatchResult> => {
  console.log('[MATCH] Starting product matching...');

  // Parse inputs (may come as JSON strings from AWSJSON type)
  let aisleEntries: AisleEntry[];
  let products: ProductInput[];

  try {
    const entriesArg = event.arguments.aisleEntries;
    aisleEntries = typeof entriesArg === 'string' ? JSON.parse(entriesArg) : entriesArg;

    const productsArg = event.arguments.products;
    products = typeof productsArg === 'string' ? JSON.parse(productsArg) : productsArg;
  } catch (parseError) {
    console.error('[MATCH] Parse error:', parseError);
    return {
      success: false,
      mappings: [],
      stats: { total: 0, highConfidence: 0, mediumConfidence: 0, lowConfidence: 0 },
      error: `Failed to parse inputs: ${parseError}`,
    };
  }

  console.log(`[MATCH] Matching ${products.length} products against ${aisleEntries.length} aisle entries`);

  if (!products || products.length === 0) {
    return {
      success: false,
      mappings: [],
      stats: { total: 0, highConfidence: 0, mediumConfidence: 0, lowConfidence: 0 },
      error: 'No products provided',
    };
  }

  if (!aisleEntries || aisleEntries.length === 0) {
    return {
      success: false,
      mappings: [],
      stats: { total: 0, highConfidence: 0, mediumConfidence: 0, lowConfidence: 0 },
      error: 'No aisle entries provided',
    };
  }

  try {
    const anthropic = new Anthropic({
      apiKey: ANTHROPIC_API_KEY,
    });

    // Format aisle directory for prompt
    const aisleDirectory = aisleEntries
      .map((e) => `- "${e.productName}" → Aisle ${e.aisle}`)
      .join('\n');

    // Format products for prompt
    const productList = JSON.stringify(
      products.map((p) => ({ id: p.id, name: p.name })),
      null,
      2
    );

    const prompt = `You are matching grocery products to store aisles.

STORE AISLE DIRECTORY (extracted from store sign):
${aisleDirectory}

PRODUCTS TO MATCH:
${productList}

For EACH product, find the best matching aisle from the directory above.

Return a JSON array:
[
  {
    "productId": "the-product-id",
    "aisleId": "4",
    "confidence": 0.95,
    "reasoning": "Matches 'Canned Tomatoes' in aisle 4"
  },
  ...
]

Confidence guidelines:
- 1.0 = Exact match (product name matches directory entry exactly)
- 0.8-0.99 = Strong match (clear category/type match)
- 0.5-0.79 = Likely match (same general category)
- 0.3-0.49 = Weak guess (might be in this aisle)
- <0.3 = Very uncertain

If no reasonable match exists, use aisleId "Unknown" with low confidence.

IMPORTANT: Map EVERY product - do not skip any. Return ONLY the JSON array.`;

    console.log('[MATCH] Calling Claude for matching...');

    const response = await anthropic.messages.create({
      model: 'claude-3-5-haiku-20241022',  // Haiku is faster for text matching
      max_tokens: 16384,
      messages: [
        {
          role: 'user',
          content: prompt,
        },
      ],
    });

    const textContent = response.content.find((block) => block.type === 'text');
    if (!textContent || textContent.type !== 'text') {
      throw new Error('No text response from Claude');
    }

    console.log(`[MATCH] Claude response length: ${textContent.text.length} chars`);

    const jsonMatch = textContent.text.match(/\[[\s\S]*\]/);
    if (!jsonMatch) {
      console.error('[MATCH] No JSON found in response:', textContent.text.substring(0, 500));
      throw new Error('No valid JSON array found in Claude response');
    }

    const mappings: ProductMapping[] = JSON.parse(jsonMatch[0]);
    console.log(`[MATCH] Received ${mappings.length} mappings`);

    // Validate mappings
    for (const mapping of mappings) {
      if (!mapping.productId || !mapping.aisleId || typeof mapping.confidence !== 'number') {
        console.warn('[MATCH] Invalid mapping:', mapping);
      }
    }

    // Calculate stats
    const highConfidence = mappings.filter((m) => m.confidence >= 0.8).length;
    const mediumConfidence = mappings.filter((m) => m.confidence >= 0.5 && m.confidence < 0.8).length;
    const lowConfidence = mappings.filter((m) => m.confidence < 0.5).length;

    console.log(`[MATCH] Stats: ${highConfidence} high, ${mediumConfidence} medium, ${lowConfidence} low confidence`);

    return {
      success: true,
      mappings,
      stats: {
        total: mappings.length,
        highConfidence,
        mediumConfidence,
        lowConfidence,
      },
    };
  } catch (error) {
    console.error('[MATCH] Error:', error);
    return {
      success: false,
      mappings: [],
      stats: { total: 0, highConfidence: 0, mediumConfidence: 0, lowConfidence: 0 },
      error: error instanceof Error ? error.message : 'Unknown error',
    };
  }
};
