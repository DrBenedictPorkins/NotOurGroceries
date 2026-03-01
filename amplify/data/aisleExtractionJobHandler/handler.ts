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

Return a JSON array ONLY - no markdown, no code fences, no explanation:
[{"productName":"Canned Tomatoes","aisle":"4"},{"productName":"Pasta","aisle":"4"}]

Rules:
- Extract EVERY item visible
- Use exact product names from the sign
- For aisle: use ONLY the number (e.g., "4" not "Aisle 4") or section name (e.g., "Dairy")
- List each product separately

IMPORTANT: Return ONLY valid JSON array. No \`\`\` or other text.`;

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
}

/**
 * Extract unique aisles from OCR entries and update the store's aisleLayout
 * Groups products by aisle to create a descriptive name
 */
async function updateStoreAisleLayout(
  storeId: string,
  aisleEntries: AisleEntry[]
): Promise<void> {
  console.log(`[PHASE 1.5] Updating store aisle layout from ${aisleEntries.length} entries`);

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

  // Create StoreAisle objects
  const aisleLayout: StoreAisle[] = aisleKeys.map((aisleKey, index) => {
    const products = aisleGroups.get(aisleKey) || [];
    // Create a name from the first few products
    const sampleProducts = products.slice(0, 3).join(', ');
    const suffix = products.length > 3 ? '...' : '';

    return {
      id: `aisle-${storeId}-${aisleKey.replace(/\s+/g, '-').toLowerCase()}`,
      number: aisleKey,
      name: sampleProducts + suffix,
      displayOrder: index,
    };
  });

  console.log(`[PHASE 1.5] Created ${aisleLayout.length} aisles: ${aisleKeys.join(', ')}`);

  // Update the HouseholdStore record
  // Store as native DynamoDB List (L type), NOT a JSON string (S type).
  // AppSync AWSJSON double-encodes S-type values, breaking client parsing.
  await ddbClient.send(
    new UpdateCommand({
      TableName: HOUSEHOLD_STORE_TABLE,
      Key: { id: storeId },
      UpdateExpression: 'SET aisleLayout = :aisleLayout, updatedAt = :updatedAt',
      ExpressionAttributeValues: {
        ':aisleLayout': aisleLayout,
        ':updatedAt': new Date().toISOString(),
      },
    })
  );

  console.log(`[PHASE 1.5] Store aisle layout updated with ${aisleLayout.length} aisles`);
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

Confidence: 1.0=exact, 0.8-0.99=strong, 0.5-0.79=likely, 0.3-0.49=weak, <0.3=uncertain.
If no match, use aisleId "Unknown" with low confidence.
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
        // 1. Skip if user has override
        // 2. Skip if existing confidence is higher
        // 3. Otherwise, update

        if (existing.userAisleOverride) {
          console.log(
            `[PHASE 3] Skipping ${mapping.productId}: user override exists`
          );
          skipped++;
          continue;
        }

        if (
          existing.confidence &&
          existing.confidence >= mapping.confidence
        ) {
          console.log(
            `[PHASE 3] Skipping ${mapping.productId}: existing confidence ${existing.confidence} >= new ${mapping.confidence}`
          );
          skipped++;
          continue;
        }

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

    // Phase 1.5: Update store's aisle layout with extracted aisles
    await updateStoreAisleLayout(storeId, aisleEntries);

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

    // Mark job complete
    await updateJobStatus(jobId, {
      status: 'COMPLETE',
      detail: `Complete! Applied ${applied} mappings, skipped ${skipped}`,
      mappingsCreated: applied,
      completedAt: new Date().toISOString(),
    });

    console.log(`[HANDLER] Job ${jobId} complete. Applied: ${applied}, Skipped: ${skipped}`);
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
