import { DynamoDBStreamEvent, DynamoDBRecord } from 'aws-lambda';
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import {
  DynamoDBDocumentClient,
  UpdateCommand,
  PutCommand,
  GetCommand,
  ScanCommand,
} from '@aws-sdk/lib-dynamodb';
import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';
import { unmarshall } from '@aws-sdk/util-dynamodb';
import Anthropic from '@anthropic-ai/sdk';

const ddbClient = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const s3Client = new S3Client({});

const JOB_TABLE = process.env.JOB_TABLE_NAME!;
const PRODUCT_TABLE = process.env.PRODUCT_TABLE_NAME!;
const MAPPING_TABLE = process.env.MAPPING_TABLE_NAME!;
const BUCKET_NAME = process.env.BUCKET_NAME!;
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY!;
const HOUSEHOLD_STORE_TABLE = process.env.HOUSEHOLD_STORE_TABLE_NAME!;
const GROCERY_ITEM_TABLE = process.env.GROCERY_ITEM_TABLE_NAME!;

// Constants - Updated 2026-02-01: Haiku 3.5 + parallel batches for speed
const MAX_RETRIES = 3;
const MODEL = 'claude-haiku-4-5';
const STATUS_UPDATE_INTERVAL = 5; // Update status every N items
const BATCH_SIZE = 40; // Keep small to avoid Haiku 8192 max_tokens truncation

// Type definitions
interface AisleEntry {
  productName: string;
  aisle: string;
}

interface ProductMapping {
  productId: string;
  normalizedName: string;
  aisleId: string;
  confidence: number;
  reasoning: string;
}

interface Product {
  id: string;
  name: string;
  normalizedName: string;
}

// =============================================================================
// STATUS UPDATE HELPER
// =============================================================================

/**
 * Update job status in DynamoDB - call frequently for user feedback
 */
async function updateJobStatus(jobId: string, updates: Record<string, any>): Promise<void> {
  const updateExpr = Object.keys(updates)
    .map((k) => `#${k} = :${k}`)
    .join(', ');
  const exprNames = Object.fromEntries(Object.keys(updates).map((k) => [`#${k}`, k]));
  const exprValues = Object.fromEntries(Object.entries(updates).map(([k, v]) => [`:${k}`, v]));

  await ddbClient.send(
    new UpdateCommand({
      TableName: JOB_TABLE,
      Key: { id: jobId },
      UpdateExpression: `SET ${updateExpr}, #updatedAt = :updatedAt`,
      ExpressionAttributeNames: { ...exprNames, '#updatedAt': 'updatedAt' },
      ExpressionAttributeValues: { ...exprValues, ':updatedAt': new Date().toISOString() },
    })
  );
}

// =============================================================================
// RETRY LOGIC
// =============================================================================

/**
 * Determine if an error is retryable (soft error)
 */
function isRetryableError(error: any): boolean {
  const message = error?.message?.toLowerCase() || '';
  const statusCode = error?.status || error?.statusCode;

  // Rate limits
  if (statusCode === 429) return true;
  if (message.includes('rate limit')) return true;
  if (message.includes('too many requests')) return true;

  // Network errors
  if (message.includes('network')) return true;
  if (message.includes('timeout')) return true;
  if (message.includes('econnreset')) return true;
  if (message.includes('socket hang up')) return true;

  // Temporary service errors
  if (statusCode === 503 || statusCode === 502 || statusCode === 500) return true;
  if (message.includes('service unavailable')) return true;
  if (message.includes('internal server error')) return true;

  return false;
}

/**
 * Execute a function with retry logic for soft errors
 */
async function withRetry<T>(
  fn: () => Promise<T>,
  context: string,
  maxRetries: number = MAX_RETRIES
): Promise<T> {
  let lastError: Error | null = null;

  for (let attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      return await fn();
    } catch (error: any) {
      lastError = error;

      if (!isRetryableError(error)) {
        console.error(`[RETRY] ${context}: Hard error (not retrying):`, error.message);
        throw error;
      }

      if (attempt < maxRetries) {
        const delay = Math.min(1000 * Math.pow(2, attempt - 1), 10000); // Exponential backoff, max 10s
        console.warn(
          `[RETRY] ${context}: Attempt ${attempt}/${maxRetries} failed, retrying in ${delay}ms:`,
          error.message
        );
        await new Promise((resolve) => setTimeout(resolve, delay));
      }
    }
  }

  throw lastError;
}

// =============================================================================
// PHASE 1: OCR - Extract Aisles from Images
// =============================================================================

/**
 * Download image from S3 and convert to base64
 */
async function downloadImageAsBase64(
  imageKey: string
): Promise<{ base64: string; mediaType: string }> {
  console.log(`[PHASE 1] Downloading image: ${imageKey}`);

  const command = new GetObjectCommand({
    Bucket: BUCKET_NAME,
    Key: imageKey,
  });

  const response = await s3Client.send(command);

  if (!response.Body) {
    throw new Error(`Empty response body from S3 for key: ${imageKey}`);
  }

  const chunks: Uint8Array[] = [];
  for await (const chunk of response.Body as AsyncIterable<Uint8Array>) {
    chunks.push(chunk);
  }

  const buffer = Buffer.concat(chunks);
  const base64 = buffer.toString('base64');
  const sizeMB = (buffer.length / (1024 * 1024)).toFixed(2);
  console.log(`[PHASE 1] Downloaded image: ${sizeMB} MB`);

  let mediaType = response.ContentType || 'image/jpeg';
  if (imageKey.toLowerCase().endsWith('.png')) {
    mediaType = 'image/png';
  } else if (imageKey.toLowerCase().endsWith('.webp')) {
    mediaType = 'image/webp';
  }

  return { base64, mediaType };
}

/**
 * Extract aisle mappings from a single image using Claude OCR
 */
async function extractFromImage(
  image: { base64: string; mediaType: string },
  anthropic: Anthropic
): Promise<AisleEntry[]> {
  console.log('[PHASE 1] Calling Claude for OCR extraction...');

  const prompt = `Extract ALL product-to-aisle mappings from this grocery store aisle directory image.

STANDARD SECTIONS — if a product is listed under one of these areas, use EXACTLY this ID as the aisle value:
- "standard-produce"  → fruits, vegetables, leafy greens, fresh herbs
- "standard-meat"     → beef, chicken, pork, turkey, lamb, sausages
- "standard-seafood"  → fish, shrimp, shellfish, seafood
- "standard-dairy"    → milk, cream, yogurt, butter, cheese, eggs
- "standard-deli"     → sliced meats, deli cheese, prepared foods, cold cuts
- "standard-bakery"   → bread, rolls, muffins, cakes, pastries
- "standard-frozen"   → frozen vegetables, meals, pizza, ice cream

For numbered aisles, use ONLY the number — never add a prefix like "Aisle".

Examples:
{"productName":"Apples","aisle":"standard-produce"}
{"productName":"Cheddar","aisle":"standard-dairy"}
{"productName":"Canned Tomatoes","aisle":"4"}
{"productName":"Pasta","aisle":"4"}

Rules:
- Extract EVERY item visible
- Use exact product names from the sign
- List each product separately

Return a JSON array ONLY — no markdown, no code fences, no explanation.`;

  const response = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 8192,
    temperature: 0,
    messages: [
      {
        role: 'user',
        content: [
          {
            type: 'image',
            source: {
              type: 'base64',
              media_type: image.mediaType as 'image/jpeg' | 'image/png' | 'image/webp' | 'image/gif',
              data: image.base64,
            },
          },
          {
            type: 'text',
            text: prompt,
          },
        ],
      },
    ],
  });

  const textContent = response.content.find((block) => block.type === 'text');
  if (!textContent || textContent.type !== 'text') {
    throw new Error('No text response from Claude');
  }

  console.log(`[PHASE 1] Claude response length: ${textContent.text.length} chars`);
  console.log(`[PHASE 1] Raw response: ${textContent.text.substring(0, 300)}...`);

  // Extract JSON from response, handling markdown code fences
  let jsonText = textContent.text;

  // Remove markdown code fences if present
  const codeBlockMatch = jsonText.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (codeBlockMatch) {
    console.log('[PHASE 1] Extracted from code block');
    jsonText = codeBlockMatch[1];
  }

  const jsonMatch = jsonText.match(/\[[\s\S]*\]/);
  if (!jsonMatch) {
    console.error('[PHASE 1] No JSON found in response:', textContent.text.substring(0, 500));
    throw new Error('No valid JSON array found in Claude response');
  }

  // Try to parse, with detailed error logging
  let rawEntries: AisleEntry[];
  try {
    rawEntries = JSON.parse(jsonMatch[0]);
  } catch (parseError: any) {
    console.error(`[PHASE 1] JSON parse failed: ${parseError.message}`);
    console.error(`[PHASE 1] JSON content (last 200 chars): ...${jsonMatch[0].slice(-200)}`);
    throw parseError;
  }
  console.log(`[PHASE 1] Extracted ${rawEntries.length} aisle entries from image`);

  // Post-processing: Clean up aisle values to remove redundant "Aisle" prefix
  const entries = rawEntries.map((entry) => {
    const originalAisle = entry.aisle;
    let cleanedAisle = originalAisle;

    // Remove "Aisle " or "aisle " prefix (case-insensitive)
    const aisleMatch = cleanedAisle.match(/^aisle\s+(.+)$/i);
    if (aisleMatch) {
      cleanedAisle = aisleMatch[1].trim();
      console.log(`[PHASE 1] [CLEANUP] Stripped "Aisle" prefix: "${originalAisle}" -> "${cleanedAisle}"`);
    }

    return {
      ...entry,
      aisle: cleanedAisle,
    };
  });

  return entries;
}

/**
 * Phase 1: Process all images and extract aisle entries
 */
async function phase1ExtractAisles(
  jobId: string,
  imageKeys: string[],
  anthropic: Anthropic
): Promise<AisleEntry[]> {
  console.log(`[PHASE 1] Starting OCR extraction for ${imageKeys.length} images`);

  await updateJobStatus(jobId, {
    status: 'EXTRACTING',
    phase: 1,
    phaseLabel: 'Extracting aisles from images',
    detail: `Starting OCR for ${imageKeys.length} images...`,
  });

  const allEntries: AisleEntry[] = [];
  const seenKeys = new Set<string>();

  for (let i = 0; i < imageKeys.length; i++) {
    const imageKey = imageKeys[i];
    console.log(`[PHASE 1] Processing image ${i + 1}/${imageKeys.length}: ${imageKey}`);

    await updateJobStatus(jobId, {
      detail: `Extracting aisles from image ${i + 1}/${imageKeys.length}...`,
    });

    try {
      // Download image with retry
      const image = await withRetry(
        () => downloadImageAsBase64(imageKey),
        `Download image ${imageKey}`
      );

      // Extract aisles with retry
      const entries = await withRetry(
        () => extractFromImage(image, anthropic),
        `OCR image ${imageKey}`
      );

      // Deduplicate entries (same product + aisle)
      for (const entry of entries) {
        const key = `${entry.productName.toLowerCase()}|${entry.aisle}`;
        if (!seenKeys.has(key)) {
          seenKeys.add(key);
          allEntries.push(entry);
        }
      }

      console.log(`[PHASE 1] Image ${i + 1} complete, total entries: ${allEntries.length}`);
    } catch (error: any) {
      // For image download/auth errors, fail fast
      if (
        error.message?.includes('NoSuchKey') ||
        error.message?.includes('Access Denied') ||
        error.message?.includes('not found')
      ) {
        console.error(`[PHASE 1] Hard error for image ${imageKey}:`, error.message);
        throw new Error(`Failed to access image ${imageKey}: ${error.message}`);
      }
      throw error;
    }
  }

  console.log(`[PHASE 1] Complete. Total unique entries: ${allEntries.length}`);

  await updateJobStatus(jobId, {
    detail: `OCR complete. Extracted ${allEntries.length} aisle entries.`,
    entriesExtracted: allEntries.length,
  });

  return allEntries;
}

// =============================================================================
// PHASE 1.5: Update Store Aisle Layout
// =============================================================================

/**
 * StoreAisle structure matching iOS model
 */
interface StoreAisle {
  id: string;
  number: string;
  name: string;
  displayOrder: number;
  description?: string;
}

/**
 * Hardcoded standard sections present in virtually every US grocery store.
 * IDs match the iOS StoreService.namedDepartments stable IDs.
 * Used as extra context in LLM prompts so the model can assign perimeter
 * items (produce, dairy, meat, etc.) even when they are absent from the
 * store's numbered aisle directory.
 */
const STANDARD_SECTIONS: Record<string, string> = {
  'standard-produce': 'Fresh fruits, vegetables, leafy greens, and fresh herbs',
  'standard-meat': 'Fresh and packaged beef, chicken, pork, turkey, lamb, and sausages',
  'standard-seafood': 'Fresh and packaged fish, shrimp, shellfish, and seafood',
  'standard-dairy': 'Milk, cream, yogurt, butter, cheese, eggs, and dairy alternatives',
  'standard-deli': 'Sliced meats, deli cheese, prepared foods, and cold cuts',
  'standard-bakery': 'Fresh bread, rolls, muffins, cakes, pastries, and baked goods',
  'standard-frozen': 'Frozen vegetables, meals, pizza, ice cream, and frozen meats',
};

/**
 * Build a prompt snippet listing standard sections so the LLM knows to use
 * their IDs (e.g. "standard-produce") as aisleId for perimeter items.
 */
function buildStandardSectionsContext(): string {
  const lines = Object.entries(STANDARD_SECTIONS).map(
    ([id, desc]) => `- ID: "${id}" | ${desc}`
  );
  return lines.join('\n');
}

/**
 * Extract unique aisles from OCR entries and update the store's aisleLayout.
 * Preserves any existing standard sections (id starts with "standard-") so a
 * re-scan never removes them.
 * Returns the final combined aisleLayout.
 */
async function updateStoreAisleLayout(
  storeId: string,
  aisleEntries: AisleEntry[]
): Promise<{ layout: StoreAisle[]; householdId: string }> {
  console.log(`[PHASE 1.5] Updating store aisle layout from ${aisleEntries.length} entries`);

  // Fetch current store to preserve existing standard sections and get householdId
  const currentItem = await ddbClient.send(
    new GetCommand({ TableName: HOUSEHOLD_STORE_TABLE, Key: { id: storeId } })
  );
  const householdId: string = currentItem.Item?.householdId ?? '';
  const existingLayout: StoreAisle[] = currentItem.Item?.aisleLayout || [];
  const namedDepartments = existingLayout.filter((a: StoreAisle) => a.id.startsWith('standard-'));
  console.log(`[PHASE 1.5] Preserving ${namedDepartments.length} existing standard sections`);

  // Group entries by aisle
  const aisleGroups = new Map<string, string[]>();
  for (const entry of aisleEntries) {
    const aisle = entry.aisle;
    if (!aisleGroups.has(aisle)) {
      aisleGroups.set(aisle, []);
    }
    aisleGroups.get(aisle)!.push(entry.productName);
  }

  // Sort aisles: numbered first (sorted numerically), then named sections
  const aisleKeys = Array.from(aisleGroups.keys());
  aisleKeys.sort((a, b) => {
    const aNum = parseInt(a);
    const bNum = parseInt(b);
    const aIsNum = !isNaN(aNum);
    const bIsNum = !isNaN(bNum);

    if (aIsNum && bIsNum) return aNum - bNum;
    if (aIsNum) return -1; // Numbers before names
    if (bIsNum) return 1;
    return a.localeCompare(b); // Alphabetical for named sections
  });

  // Create StoreAisle objects for OCR-derived aisles
  const ocrAisles: StoreAisle[] = aisleKeys.map((aisleKey, index) => {
    const products = aisleGroups.get(aisleKey) || [];
    return {
      id: `aisle-${storeId}-${aisleKey.replace(/\s+/g, '-').toLowerCase()}`,
      number: aisleKey,
      // Deliberately empty. `name` is what section headers render, and putting a
      // sample of the sign's contents here produced three-line headers in At
      // Store mode — "12 - SYRUP, TEA BAGS, CHOCOLATE SYRUP…". The contents
      // belong in `description`, which is what the aisle inference prompt reads
      // and what makes the mapping good; the header only says which aisle it is.
      name: '',
      displayOrder: index,
      description: products.slice(0, 10).join(', '),
    };
  });

  // Final layout: OCR aisles + preserved standard sections (standard sections keep 900+ displayOrder)
  const finalLayout: StoreAisle[] = [...ocrAisles, ...namedDepartments];

  console.log(`[PHASE 1.5] Created ${ocrAisles.length} OCR aisles + ${namedDepartments.length} standard sections`);

  // Update the HouseholdStore record
  // Store as native DynamoDB List (L type), NOT a JSON string (S type).
  // AppSync AWSJSON double-encodes S-type values, breaking client parsing.
  await ddbClient.send(
    new UpdateCommand({
      TableName: HOUSEHOLD_STORE_TABLE,
      Key: { id: storeId },
      UpdateExpression: 'SET aisleLayout = :aisleLayout, updatedAt = :updatedAt',
      ExpressionAttributeValues: {
        ':aisleLayout': finalLayout,
        ':updatedAt': new Date().toISOString(),
      },
    })
  );

  console.log(`[PHASE 1.5] Store aisle layout updated with ${finalLayout.length} total aisles`);
  return { layout: finalLayout, householdId };
}

// =============================================================================
// PHASE 1.7: Direct OCR → Name-Based Mappings
// =============================================================================

/**
 * Normalize a product name — mirrors the normalizeName() function used by the iOS app
 * so that name lookups match at query time.
 */
function normalizeProductName(name: string): string {
  let normalized = name.toLowerCase().trim();
  normalized = normalized.replace(/^(a |an |the )/i, '');
  const exceptions = ['hummus', 'asparagus', 'couscous', 'citrus', 'cheese', 'rice', 'clothes'];
  if (normalized.endsWith('ies') && normalized.length > 4) {
    normalized = normalized.slice(0, -3) + 'y';
  } else if (normalized.endsWith('oes') && normalized.length > 4) {
    normalized = normalized.slice(0, -2);
  } else if (normalized.endsWith('ves') && normalized.length > 4) {
    normalized = normalized.slice(0, -3) + 'f';
  } else if (normalized.endsWith('es') && normalized.length > 3 && !exceptions.includes(normalized)) {
    const stem = normalized.slice(0, -2);
    if (stem.endsWith('s') || stem.endsWith('sh') || stem.endsWith('ch') || stem.endsWith('x') || stem.endsWith('z')) {
      normalized = stem;
    } else {
      normalized = normalized.slice(0, -1);
    }
  } else if (normalized.endsWith('s') && normalized.length > 2 && !exceptions.includes(normalized)) {
    normalized = normalized.slice(0, -1);
  }
  return normalized.trim();
}

/**
 * Phase 1.7: Save all OCR entries directly as normalizedName-based mappings.
 *
 * This runs BEFORE catalog matching so that items on the store sign that have
 * no matching catalog product are not silently dropped. Custom user items
 * (which have no productId) will match these by normalizedName.
 *
 * ID format: `${storeId}-name-${normalizedName}` — distinct from the
 * productId-based format `${storeId}-${productId}` used in Phase 3, so both
 * coexist without conflict.
 */
async function phase1p7DirectOCRMappings(
  jobId: string,
  storeId: string,
  aisleEntries: AisleEntry[],
  imageKeys: string[]
): Promise<number> {
  console.log(`[PHASE 1.7] Creating direct name-based mappings for ${aisleEntries.length} OCR entries`);

  await updateJobStatus(jobId, {
    detail: `Saving ${aisleEntries.length} direct name mappings from image...`,
  });

  const now = new Date().toISOString();
  const seen = new Set<string>();
  let saved = 0;

  for (const entry of aisleEntries) {
    const normalizedName = normalizeProductName(entry.productName);
    if (!normalizedName || seen.has(normalizedName)) continue;
    seen.add(normalizedName);

    // ID uses "name-" prefix to avoid colliding with productId-based mappings
    const mappingId = `${storeId}-name-${normalizedName.replace(/\s+/g, '-')}`;

    try {
      // Never overwrite a user override
      const existing = await ddbClient.send(
        new GetCommand({ TableName: MAPPING_TABLE, Key: { id: mappingId } })
      );
      if (existing.Item?.userAisleOverride) {
        console.log(`[PHASE 1.7] Skipping "${normalizedName}": user override exists`);
        continue;
      }

      await ddbClient.send(
        new PutCommand({
          TableName: MAPPING_TABLE,
          Item: {
            id: mappingId,
            storeId,
            normalizedName,
            aisleId: entry.aisle,
            confidence: 1.0,
            source: 'IMAGE',
            reasoning: `Directly listed on store sign: "${entry.productName}"`,
            sourceImageKeys: imageKeys,
            mappedAt: now,
            createdAt: existing.Item?.createdAt ?? now,
            updatedAt: now,
          },
        })
      );

      saved++;
    } catch (error: any) {
      console.error(`[PHASE 1.7] Error saving mapping for "${normalizedName}":`, error.message);
      // Continue — don't let one failure abort the rest
    }
  }

  console.log(`[PHASE 1.7] Saved ${saved} direct name-based mappings`);
  return saved;
}

// =============================================================================
// PHASE 2: Match Products to Aisles
// =============================================================================

/**
 * Fetch all products from the Product table
 */
async function fetchAllProducts(): Promise<Product[]> {
  console.log('[PHASE 2] Fetching all products from database...');

  const products: Product[] = [];
  let lastEvaluatedKey: Record<string, any> | undefined;

  do {
    const result = await ddbClient.send(
      new ScanCommand({
        TableName: PRODUCT_TABLE,
        ExclusiveStartKey: lastEvaluatedKey,
        ProjectionExpression: 'id, #name, normalizedName',
        ExpressionAttributeNames: { '#name': 'name' },
      })
    );

    if (result.Items) {
      products.push(
        ...result.Items.map((item) => ({
          id: item.id as string,
          name: item.name as string,
          normalizedName: item.normalizedName as string,
        }))
      );
    }

    lastEvaluatedKey = result.LastEvaluatedKey;
  } while (lastEvaluatedKey);

  console.log(`[PHASE 2] Fetched ${products.length} products`);
  return products;
}

/**
 * Match a batch of products to aisle entries using Claude
 */
async function matchProductBatch(
  products: Product[],
  aisleEntries: AisleEntry[],
  anthropic: Anthropic
): Promise<ProductMapping[]> {
  // Format aisle directory for prompt
  const aisleDirectory = aisleEntries.map((e) => `- "${e.productName}" -> Aisle ${e.aisle}`).join('\n');

  // Format products for prompt
  const productList = JSON.stringify(
    products.map((p) => ({ id: p.id, name: p.name })),
    null,
    2
  );

  const namedDepartmentsContext = buildStandardSectionsContext();

  const prompt = `You are matching grocery products to store aisles.

STORE AISLE DIRECTORY (extracted from store sign):
${aisleDirectory}

STANDARD STORE SECTIONS (perimeter areas not in the numbered directory):
${namedDepartmentsContext}
Use the section ID (e.g. "standard-produce") as the aisleId for products in these sections.

PRODUCTS TO MATCH:
${productList}

For EACH product, find the best matching aisle from the directory above, OR the best matching standard section if the product belongs there (e.g. fresh produce, meat, dairy, deli, bakery, seafood, frozen).

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

For standard section matches use the section ID: e.g. "aisleId": "standard-produce"
Confidence: 1.0=exact, 0.8-0.99=strong, 0.5-0.79=likely, 0.3-0.49=weak, <0.3=uncertain.
If no match anywhere, use aisleId "Unknown" with low confidence.
Keep reasoning SHORT (under 10 words). Map EVERY product. Return ONLY the JSON array.`;

  const response = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 8192, // Haiku 3.5 max output cap
    temperature: 0,
    messages: [
      {
        role: 'user',
        content: prompt,
      },
    ],
  });

  // Detect truncation from max_tokens limit
  if (response.stop_reason === 'max_tokens') {
    console.error(`[PHASE 2] Response truncated by max_tokens (${products.length} products too many for batch)`);
    throw new Error(`Response truncated: batch of ${products.length} products exceeds token limit`);
  }

  const textContent = response.content.find((block) => block.type === 'text');
  if (!textContent || textContent.type !== 'text') {
    throw new Error('No text response from Claude');
  }

  // Extract JSON from response, handling markdown code fences
  let jsonText = textContent.text;

  // Remove markdown code fences if present
  const codeBlockMatch = jsonText.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (codeBlockMatch) {
    jsonText = codeBlockMatch[1];
  }

  const jsonMatch = jsonText.match(/\[[\s\S]*\]/);
  if (!jsonMatch) {
    console.error('[PHASE 2] No JSON found in response:', textContent.text.substring(0, 500));
    throw new Error('No valid JSON array found in Claude response');
  }

  const mappings: ProductMapping[] = JSON.parse(jsonMatch[0]);

  // Add normalizedName to each mapping
  const productMap = new Map(products.map((p) => [p.id, p]));
  for (const mapping of mappings) {
    const product = productMap.get(mapping.productId);
    if (product) {
      mapping.normalizedName = product.normalizedName;
    }
  }

  return mappings;
}

/**
 * Phase 2: Match all products to extracted aisle entries
 */
async function phase2MatchProducts(
  jobId: string,
  aisleEntries: AisleEntry[],
  anthropic: Anthropic
): Promise<ProductMapping[]> {
  console.log('[PHASE 2] Starting product matching...');

  await updateJobStatus(jobId, {
    status: 'MATCHING',
    phase: 2,
    phaseLabel: 'Matching products to aisles',
    detail: 'Fetching products from database...',
  });

  // Fetch all products
  const products = await fetchAllProducts();

  if (products.length === 0) {
    console.log('[PHASE 2] No products found in database');
    return [];
  }

  await updateJobStatus(jobId, {
    detail: `Matching ${products.length} products to aisles...`,
  });

  // Use module-level BATCH_SIZE constant

  // Create all batches
  const batches: { batch: typeof products; batchNum: number }[] = [];
  for (let i = 0; i < products.length; i += BATCH_SIZE) {
    batches.push({
      batch: products.slice(i, i + BATCH_SIZE),
      batchNum: Math.floor(i / BATCH_SIZE) + 1,
    });
  }

  console.log(`[PHASE 2] Processing ${batches.length} batches in PARALLEL`);

  await updateJobStatus(jobId, {
    detail: `Matching ${products.length} products in ${batches.length} parallel batches...`,
  });

  // Run all batches in parallel
  const batchResults = await Promise.all(
    batches.map(async ({ batch, batchNum }) => {
      console.log(`[PHASE 2] Starting batch ${batchNum}/${batches.length} (${batch.length} products)`);
      const mappings = await withRetry(
        () => matchProductBatch(batch, aisleEntries, anthropic),
        `Match batch ${batchNum}`
      );
      console.log(`[PHASE 2] Batch ${batchNum} complete: ${mappings.length} mappings`);
      return mappings;
    })
  );

  // Flatten results
  const allMappings: ProductMapping[] = batchResults.flat();

  console.log(`[PHASE 2] Complete. Total mappings: ${allMappings.length}`);

  // Calculate stats
  const highConfidence = allMappings.filter((m) => m.confidence >= 0.8).length;
  const mediumConfidence = allMappings.filter((m) => m.confidence >= 0.5 && m.confidence < 0.8).length;
  const lowConfidence = allMappings.filter((m) => m.confidence < 0.5).length;

  await updateJobStatus(jobId, {
    detail: `Matched ${allMappings.length} products. High: ${highConfidence}, Medium: ${mediumConfidence}, Low: ${lowConfidence}`,
    highConfidence: highConfidence,
    lowConfidence: lowConfidence,
  });

  return allMappings;
}

// =============================================================================
// PHASE 3: Apply Mappings to ProductAisleMapping Table
// =============================================================================

/**
 * Get existing mapping from database
 * Uses the composite key format: storeId-productId as the mapping id
 */
async function getExistingMapping(
  storeId: string,
  productId: string
): Promise<Record<string, any> | null> {
  // The mapping id is a composite of storeId-productId
  const mappingId = `${storeId}-${productId}`;

  try {
    const result = await ddbClient.send(
      new GetCommand({
        TableName: MAPPING_TABLE,
        Key: { id: mappingId },
      })
    );

    return result.Item || null;
  } catch (error) {
    // Mapping doesn't exist
    return null;
  }
}

/**
 * Phase 3: Write mappings to ProductAisleMapping table with smart merge
 */
async function phase3ApplyMappings(
  jobId: string,
  storeId: string,
  mappings: ProductMapping[],
  imageKeys: string[]
): Promise<{ applied: number; skipped: number }> {
  console.log(`[PHASE 3] Applying ${mappings.length} mappings to database`);

  await updateJobStatus(jobId, {
    status: 'APPLYING',
    phase: 3,
    phaseLabel: 'Applying aisle mappings',
    detail: `Writing ${mappings.length} mappings to database...`,
  });

  let applied = 0;
  let skipped = 0;
  const now = new Date().toISOString();

  for (let i = 0; i < mappings.length; i++) {
    const mapping = mappings[i];

    // Skip if aisleId is "Unknown"
    if (mapping.aisleId === 'Unknown') {
      skipped++;
      continue;
    }

    try {
      // Check for existing mapping
      const existing = await getExistingMapping(storeId, mapping.productId);

      if (existing) {
        // Smart merge logic:
        // 1. Skip if user has override — always respected
        // 2. Always overwrite if new source is IMAGE — a fresh scan beats any previous scan or inference
        // 3. Otherwise skip (e.g. LLM_INFER trying to overwrite a good IMAGE mapping)

        if (existing.userAisleOverride) {
          console.log(
            `[PHASE 3] Skipping ${mapping.productId}: user override exists`
          );
          skipped++;
          continue;
        }

        // IMAGE source always wins — trust the latest scan over any previous mapping
        // (confidence check dropped: a fresh scan is more current than an old confident one)

        // Update existing mapping
        await ddbClient.send(
          new UpdateCommand({
            TableName: MAPPING_TABLE,
            Key: { id: existing.id },
            UpdateExpression:
              'SET aisleId = :aisleId, confidence = :confidence, reasoning = :reasoning, sourceImageKeys = :imageKeys, mappedAt = :mappedAt, #source = :source, updatedAt = :updatedAt',
            ExpressionAttributeNames: { '#source': 'source' },
            ExpressionAttributeValues: {
              ':aisleId': mapping.aisleId,
              ':confidence': mapping.confidence,
              ':reasoning': mapping.reasoning,
              ':imageKeys': imageKeys,
              ':mappedAt': now,
              ':source': 'IMAGE',
              ':updatedAt': now,
            },
          })
        );

        applied++;
      } else {
        // Create new mapping
        const mappingId = `${storeId}-${mapping.productId}`;

        await ddbClient.send(
          new PutCommand({
            TableName: MAPPING_TABLE,
            Item: {
              id: mappingId,
              storeId: storeId,
              productId: mapping.productId,
              normalizedName: mapping.normalizedName,
              aisleId: mapping.aisleId,
              confidence: mapping.confidence,
              source: 'IMAGE',
              reasoning: mapping.reasoning,
              sourceImageKeys: imageKeys,
              mappedAt: now,
              createdAt: now,
              updatedAt: now,
            },
          })
        );

        applied++;
      }
    } catch (error: any) {
      console.error(
        `[PHASE 3] Error applying mapping for ${mapping.productId}:`,
        error.message
      );
      // Continue with other mappings
    }

    // Update progress every few items
    if ((i + 1) % STATUS_UPDATE_INTERVAL === 0) {
      await updateJobStatus(jobId, {
        detail: `Applied ${applied} of ${mappings.length} mappings (${skipped} skipped)...`,
      });
    }
  }

  console.log(`[PHASE 3] Complete. Applied: ${applied}, Skipped: ${skipped}`);

  return { applied, skipped };
}

// =============================================================================
// PHASE 4: AI Inference for Unmapped Products
// =============================================================================

/**
 * Fetch products that have no usable mapping for this store.
 * Treats LLM_INFER mappings as unmapped so they get re-inferred with the
 * updated store layout context on re-scan. IMAGE mappings and user overrides
 * are considered final and are skipped.
 */
async function fetchUnmappedProducts(
  storeId: string,
  products: Product[]
): Promise<Product[]> {
  console.log(`[PHASE 4] Checking ${products.length} products for existing mappings...`);

  const unmapped: Product[] = [];

  for (const product of products) {
    const existing = await getExistingMapping(storeId, product.id);
    if (!existing || existing.source === 'LLM_GUESS') {
      // No mapping, or only an inference — eligible for re-inference with fresh store context
      // (user overrides are stored in userAisleOverride field, not source, so this is safe)
      if (existing?.userAisleOverride) continue;
      unmapped.push(product);
    }
  }

  console.log(`[PHASE 4] Found ${unmapped.length} products needing inference for store ${storeId}`);
  return unmapped;
}

/**
 * Infer aisles for a batch of unmapped products using the store's aisle directory.
 * Returns mappings with source LLM_INFER.
 */
async function inferUnmappedBatch(
  products: Product[],
  aisleEntries: AisleEntry[],
  anthropic: Anthropic
): Promise<ProductMapping[]> {
  const aisleDirectory = aisleEntries
    .map((e) => `- "${e.productName}" -> Aisle ${e.aisle}`)
    .join('\n');

  const productList = JSON.stringify(
    products.map((p) => ({ id: p.id, name: p.name })),
    null,
    2
  );

  const namedDepartmentsContext = buildStandardSectionsContext();

  const prompt = `You are assigning grocery products to store aisles based on general grocery store knowledge.

STORE AISLE DIRECTORY (what this store stocks in each aisle):
${aisleDirectory}

STANDARD STORE SECTIONS (perimeter areas not in the numbered directory):
${namedDepartmentsContext}
Use the section ID (e.g. "standard-produce") as the aisleId for products in these sections.

PRODUCTS TO ASSIGN (not found in store scan — use your best judgment):
${productList}

For EACH product, pick the most likely aisle from the directory above, OR the best matching standard section if the product belongs there (fresh produce, meat, dairy, deli, bakery, seafood, frozen).
If there is genuinely no reasonable match anywhere, use "Unknown".

Return a JSON array:
[
  {
    "productId": "the-product-id",
    "aisleId": "4",
    "confidence": 0.65,
    "reasoning": "Likely near similar items in aisle 4"
  },
  ...
]

For standard section matches use the section ID: e.g. "aisleId": "standard-produce"
Confidence: 0.5-0.69=reasonable guess, 0.3-0.49=weak guess, <0.3=very uncertain.
Do NOT use confidence above 0.7 — these are inferences, not confirmed mappings.
Map EVERY product. Return ONLY the JSON array.`;

  const response = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 8192,
    temperature: 0,
    messages: [{ role: 'user', content: prompt }],
  });

  if (response.stop_reason === 'max_tokens') {
    console.error(`[PHASE 4] Response truncated (${products.length} products)`);
    throw new Error(`Response truncated: batch of ${products.length} products exceeds token limit`);
  }

  const textContent = response.content.find((block) => block.type === 'text');
  if (!textContent || textContent.type !== 'text') {
    throw new Error('No text response from Claude');
  }

  let jsonText = textContent.text;
  const codeBlockMatch = jsonText.match(/```(?:json)?\s*([\s\S]*?)```/);
  if (codeBlockMatch) {
    jsonText = codeBlockMatch[1];
  }

  const jsonMatch = jsonText.match(/\[[\s\S]*\]/);
  if (!jsonMatch) {
    console.error('[PHASE 4] No JSON found in response:', textContent.text.substring(0, 500));
    throw new Error('No valid JSON array found in Claude response');
  }

  const mappings: ProductMapping[] = JSON.parse(jsonMatch[0]);

  const productMap = new Map(products.map((p) => [p.id, p]));
  for (const mapping of mappings) {
    const product = productMap.get(mapping.productId);
    if (product) {
      mapping.normalizedName = product.normalizedName;
    }
  }

  return mappings;
}

/**
 * Phase 4: Infer aisles for all catalog products still unmapped after Phases 1-3.
 * Saves results as LLM_INFER mappings — never overwrites existing mappings.
 */
async function phase4InferUnmappedProducts(
  jobId: string,
  storeId: string,
  aisleEntries: AisleEntry[],
  anthropic: Anthropic
): Promise<number> {
  console.log('[PHASE 4] Starting AI inference for unmapped products...');

  await updateJobStatus(jobId, {
    phase: 4,
    phaseLabel: 'Inferring unmapped products',
    detail: 'Checking for unmapped products...',
  });

  const allProducts = await fetchAllProducts();

  if (allProducts.length === 0) {
    console.log('[PHASE 4] No products in catalog, skipping');
    return 0;
  }

  const unmapped = await fetchUnmappedProducts(storeId, allProducts);

  if (unmapped.length === 0) {
    console.log('[PHASE 4] All products already mapped, skipping');
    return 0;
  }

  await updateJobStatus(jobId, {
    detail: `Inferring aisles for ${unmapped.length} unmapped products...`,
  });

  // Batch inference in parallel (same batch size as Phase 2)
  const batches: { batch: typeof unmapped; batchNum: number }[] = [];
  for (let i = 0; i < unmapped.length; i += BATCH_SIZE) {
    batches.push({
      batch: unmapped.slice(i, i + BATCH_SIZE),
      batchNum: Math.floor(i / BATCH_SIZE) + 1,
    });
  }

  console.log(`[PHASE 4] Running ${batches.length} inference batches in parallel`);

  const batchResults = await Promise.all(
    batches.map(async ({ batch, batchNum }) => {
      console.log(`[PHASE 4] Starting batch ${batchNum}/${batches.length} (${batch.length} products)`);
      const mappings = await withRetry(
        () => inferUnmappedBatch(batch, aisleEntries, anthropic),
        `Infer batch ${batchNum}`
      );
      console.log(`[PHASE 4] Batch ${batchNum} complete: ${mappings.length} mappings`);
      return mappings;
    })
  );

  const allMappings = batchResults.flat();

  // Save inferred mappings — skip Unknown; skip if an IMAGE mapping appeared during inference
  let saved = 0;
  const now = new Date().toISOString();

  for (const mapping of allMappings) {
    if (mapping.aisleId === 'Unknown') continue;

    try {
      // Re-check: an IMAGE mapping may have been written by Phase 3 during our parallel run
      const existing = await getExistingMapping(storeId, mapping.productId);
      if (existing && existing.source !== 'LLM_GUESS') {
        console.log(`[PHASE 4] Skipping ${mapping.productId}: IMAGE mapping appeared during inference`);
        continue;
      }

      const mappingId = `${storeId}-${mapping.productId}`;
      const cappedConfidence = Math.min(mapping.confidence, 0.7);

      if (existing?.source === 'LLM_GUESS') {
        // Update the existing LLM_INFER record with fresh inference from new store layout
        await ddbClient.send(
          new UpdateCommand({
            TableName: MAPPING_TABLE,
            Key: { id: mappingId },
            UpdateExpression:
              'SET aisleId = :aisleId, confidence = :confidence, reasoning = :reasoning, mappedAt = :mappedAt, updatedAt = :updatedAt',
            ExpressionAttributeValues: {
              ':aisleId': mapping.aisleId,
              ':confidence': cappedConfidence,
              ':reasoning': mapping.reasoning,
              ':mappedAt': now,
              ':updatedAt': now,
            },
          })
        );
      } else {
        // Create new LLM_INFER mapping
        await ddbClient.send(
          new PutCommand({
            TableName: MAPPING_TABLE,
            Item: {
              id: mappingId,
              storeId: storeId,
              productId: mapping.productId,
              normalizedName: mapping.normalizedName,
              aisleId: mapping.aisleId,
              confidence: cappedConfidence,
              source: 'LLM_GUESS',
              reasoning: mapping.reasoning,
              mappedAt: now,
              createdAt: now,
              updatedAt: now,
            },
          })
        );
      }

      saved++;
    } catch (error: any) {
      console.error(`[PHASE 4] Error saving mapping for ${mapping.productId}:`, error.message);
    }
  }

  console.log(`[PHASE 4] Complete. Inferred and saved ${saved} mappings`);
  return saved;
}

// =============================================================================
// PHASE 5: Infer Aisles for Custom Household Items
// =============================================================================

interface CustomItem {
  id: string;
  name: string;
  normalizedName: string;
}

/**
 * Scan GroceryItem table for all custom items belonging to a household.
 * Custom items (isCustom=true) have no productId and are matched only by normalizedName.
 */
async function fetchCustomHouseholdItems(householdId: string): Promise<CustomItem[]> {
  console.log(`[PHASE 5] Fetching custom items for household ${householdId}`);

  const items: CustomItem[] = [];
  let lastEvaluatedKey: Record<string, any> | undefined;

  do {
    const result = await ddbClient.send(
      new ScanCommand({
        TableName: GROCERY_ITEM_TABLE,
        FilterExpression: 'isCustom = :true AND householdId = :householdId',
        ExpressionAttributeValues: {
          ':true': true,
          ':householdId': householdId,
        },
        ProjectionExpression: 'id, #name, normalizedName',
        ExpressionAttributeNames: { '#name': 'name' },
        ExclusiveStartKey: lastEvaluatedKey,
      })
    );

    if (result.Items) {
      for (const item of result.Items) {
        if (item.id && item.name && item.normalizedName) {
          items.push({
            id: item.id as string,
            name: item.name as string,
            normalizedName: item.normalizedName as string,
          });
        }
      }
    }

    lastEvaluatedKey = result.LastEvaluatedKey;
  } while (lastEvaluatedKey);

  // Deduplicate by normalizedName (same item may appear multiple times in a household's history)
  const seen = new Set<string>();
  const unique: CustomItem[] = [];
  for (const item of items) {
    if (!seen.has(item.normalizedName)) {
      seen.add(item.normalizedName);
      unique.push(item);
    }
  }

  console.log(`[PHASE 5] Found ${unique.length} unique custom items for household`);
  return unique;
}

/**
 * Phase 5: Infer aisles for custom household items that have no existing mapping.
 * Uses the same LLM inference as Phase 4, but for user-created items (no productId).
 * Saves results as LLM_GUESS name-based mappings (id: ${storeId}-name-${normalizedName}).
 */
async function phase5InferCustomItems(
  jobId: string,
  storeId: string,
  householdId: string,
  aisleEntries: AisleEntry[],
  anthropic: Anthropic
): Promise<number> {
  console.log('[PHASE 5] Starting AI inference for custom household items...');

  await updateJobStatus(jobId, {
    phase: 5,
    phaseLabel: 'Inferring custom item aisles',
    detail: 'Checking for unmapped custom items...',
  });

  const allCustomItems = await fetchCustomHouseholdItems(householdId);

  if (allCustomItems.length === 0) {
    console.log('[PHASE 5] No custom items found, skipping');
    return 0;
  }

  // Filter to items with no existing name-based mapping for this store
  const unmapped: CustomItem[] = [];
  for (const item of allCustomItems) {
    const mappingId = `${storeId}-name-${item.normalizedName.replace(/\s+/g, '-')}`;
    const existing = await ddbClient.send(
      new GetCommand({ TableName: MAPPING_TABLE, Key: { id: mappingId } })
    );
    if (!existing.Item || (existing.Item.source === 'LLM_GUESS' && !existing.Item.userAisleOverride)) {
      unmapped.push(item);
    }
  }

  if (unmapped.length === 0) {
    console.log('[PHASE 5] All custom items already have IMAGE or user-override mappings, skipping');
    return 0;
  }

  console.log(`[PHASE 5] ${unmapped.length} custom items need inference`);

  await updateJobStatus(jobId, {
    detail: `Inferring aisles for ${unmapped.length} custom items...`,
  });

  // Reuse inferUnmappedBatch — pass custom items as Product-shaped objects with empty id
  // (productId is not used for name-based mappings)
  const productShapedItems = unmapped.map((item) => ({
    id: item.id,
    name: item.name,
    normalizedName: item.normalizedName,
  }));

  const batches: { batch: typeof productShapedItems; batchNum: number }[] = [];
  for (let i = 0; i < productShapedItems.length; i += BATCH_SIZE) {
    batches.push({
      batch: productShapedItems.slice(i, i + BATCH_SIZE),
      batchNum: Math.floor(i / BATCH_SIZE) + 1,
    });
  }

  const batchResults = await Promise.all(
    batches.map(async ({ batch, batchNum }) => {
      const mappings = await withRetry(
        () => inferUnmappedBatch(batch, aisleEntries, anthropic),
        `Phase5 batch ${batchNum}`
      );
      return mappings;
    })
  );

  const allMappings = batchResults.flat();

  // Save as name-based LLM_GUESS mappings
  let saved = 0;
  const now = new Date().toISOString();
  const itemMap = new Map(unmapped.map((item) => [item.id, item]));

  for (const mapping of allMappings) {
    if (mapping.aisleId === 'Unknown') continue;

    const item = itemMap.get(mapping.productId); // productId field holds the item.id from productShapedItems
    if (!item) continue;

    const mappingId = `${storeId}-name-${item.normalizedName.replace(/\s+/g, '-')}`;
    const cappedConfidence = Math.min(mapping.confidence, 0.7);

    try {
      // Re-check: don't overwrite an IMAGE or user-override mapping
      const existing = await ddbClient.send(
        new GetCommand({ TableName: MAPPING_TABLE, Key: { id: mappingId } })
      );
      if (existing.Item && existing.Item.source !== 'LLM_GUESS') continue;
      if (existing.Item?.userAisleOverride) continue;

      await ddbClient.send(
        new PutCommand({
          TableName: MAPPING_TABLE,
          Item: {
            id: mappingId,
            storeId,
            normalizedName: item.normalizedName,
            aisleId: mapping.aisleId,
            confidence: cappedConfidence,
            source: 'LLM_GUESS',
            reasoning: mapping.reasoning,
            mappedAt: now,
            createdAt: existing.Item?.createdAt ?? now,
            updatedAt: now,
          },
        })
      );

      saved++;
    } catch (error: any) {
      console.error(`[PHASE 5] Error saving mapping for "${item.normalizedName}":`, error.message);
    }
  }

  console.log(`[PHASE 5] Complete. Saved ${saved} custom item mappings`);
  return saved;
}

// =============================================================================
// MAIN HANDLER
// =============================================================================

/**
 * Process a single AisleExtractionJob record
 */
async function processJob(record: DynamoDBRecord): Promise<void> {
  // Parse the new image from the stream record
  if (!record.dynamodb?.NewImage) {
    console.log('[HANDLER] No NewImage in record, skipping');
    return;
  }

  const newImage = unmarshall(record.dynamodb.NewImage as any);
  const jobId = newImage.id as string;
  const storeId = newImage.storeId as string;
  const imageKeys = (newImage.imageKeys || []) as string[];

  console.log(`[HANDLER] Processing job ${jobId} for store ${storeId}`);
  console.log(`[HANDLER] Image keys: ${imageKeys.join(', ')}`);

  if (!storeId || imageKeys.length === 0) {
    console.error('[HANDLER] Missing storeId or imageKeys');
    await updateJobStatus(jobId, {
      status: 'FAILED',
      detail: 'Missing required fields: storeId or imageKeys',
    });
    return;
  }

  try {
    // Initialize Anthropic client
    const anthropic = new Anthropic({
      apiKey: ANTHROPIC_API_KEY,
    });

    // Phase 1: OCR - Extract aisles from images
    const aisleEntries = await phase1ExtractAisles(jobId, imageKeys, anthropic);

    if (aisleEntries.length === 0) {
      await updateJobStatus(jobId, {
        status: 'FAILED',
        detail: 'No aisle entries could be extracted from images',
      });
      return;
    }

    // Phase 1.5: Update store's aisle layout with extracted aisles (preserves standard sections)
    const { householdId } = await updateStoreAisleLayout(storeId, aisleEntries);

    // Phase 1.7: Save all OCR entries as direct name-based mappings
    // This preserves items not in the catalog (e.g. "Beer" → "Beer Garden")
    // and enables aisle lookup for custom user-added items
    const directMappings = await phase1p7DirectOCRMappings(jobId, storeId, aisleEntries, imageKeys);

    // Phase 2: Match products to aisles
    const mappings = await phase2MatchProducts(jobId, aisleEntries, anthropic);

    if (mappings.length === 0) {
      await updateJobStatus(jobId, {
        status: 'COMPLETE',
        detail: 'No products to match (product database may be empty)',
        mappingsCreated: 0,
        completedAt: new Date().toISOString(),
      });
      return;
    }

    // Phase 3: Apply mappings to database
    const { applied, skipped } = await phase3ApplyMappings(
      jobId,
      storeId,
      mappings,
      imageKeys
    );

    // Phase 4: AI inference for catalog products still unmapped after Phases 1-3
    const inferred = await phase4InferUnmappedProducts(jobId, storeId, aisleEntries, anthropic);

    // Phase 5: Infer aisles for custom household items (no productId, matched by name)
    const customInferred = householdId
      ? await phase5InferCustomItems(jobId, storeId, householdId, aisleEntries, anthropic)
      : 0;

    // Mark job complete
    await updateJobStatus(jobId, {
      status: 'COMPLETE',
      detail: `Complete! ${directMappings} direct + ${applied} catalog + ${inferred} inferred + ${customInferred} custom mappings, ${skipped} skipped`,
      mappingsCreated: directMappings + applied + inferred + customInferred,
      completedAt: new Date().toISOString(),
    });

    console.log(`[HANDLER] Job ${jobId} complete. Applied: ${applied}, Inferred: ${inferred}, Custom: ${customInferred}, Skipped: ${skipped}`);
  } catch (error: any) {
    console.error(`[HANDLER] Job ${jobId} failed:`, error);

    await updateJobStatus(jobId, {
      status: 'FAILED',
      detail: `Error: ${error.message}`,
      lastError: error.message,
      failedAt: new Date().toISOString(),
    });
  }
}

/**
 * Main Lambda handler - processes DynamoDB Stream events
 */
export const handler = async (event: DynamoDBStreamEvent): Promise<void> => {
  console.log(`[HANDLER] Received ${event.Records.length} records`);

  for (const record of event.Records) {
    // Only process INSERT events (new jobs)
    if (record.eventName !== 'INSERT') {
      console.log(`[HANDLER] Skipping ${record.eventName} event`);
      continue;
    }

    try {
      await processJob(record);
    } catch (error) {
      console.error('[HANDLER] Error processing record:', error);
      // Continue processing other records
    }
  }
};
