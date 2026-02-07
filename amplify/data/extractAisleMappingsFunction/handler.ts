import { S3Client, GetObjectCommand, DeleteObjectCommand } from '@aws-sdk/client-s3';
import { DynamoDBClient, PutItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall } from '@aws-sdk/util-dynamodb';
import Anthropic from '@anthropic-ai/sdk';
import type { AppSyncResolverEvent } from 'aws-lambda';

const s3Client = new S3Client({});
const dynamoClient = new DynamoDBClient({});

const BUCKET_NAME = process.env.BUCKET_NAME!;
const PRODUCT_AISLE_MAPPING_TABLE_NAME = process.env.PRODUCT_AISLE_MAPPING_TABLE_NAME!;
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY!;

interface HandlerArguments {
  imageKey: string;
  storeId: string;
}

interface ProductMapping {
  product: string;
  aisle: string;
}

interface ExtractedData {
  storeName?: string;
  mappings: ProductMapping[];
}

interface AisleGroup {
  id: string;
  number: string;
  name: string;
  products: Array<{
    id: string;
    name: string;
    confidence: string;
  }>;
}

interface ExtractionResult {
  success: boolean;
  aisles?: AisleGroup[];
  totalProducts?: number;
  error?: string;
}

/**
 * Download image from S3 and convert to base64
 */
async function downloadImageAsBase64(imageKey: string): Promise<{ base64: string; mediaType: string }> {
  const command = new GetObjectCommand({
    Bucket: BUCKET_NAME,
    Key: imageKey,
  });

  const response = await s3Client.send(command);

  if (!response.Body) {
    throw new Error('Empty response body from S3');
  }

  const chunks: Uint8Array[] = [];
  for await (const chunk of response.Body as AsyncIterable<Uint8Array>) {
    chunks.push(chunk);
  }

  const buffer = Buffer.concat(chunks);
  const base64 = buffer.toString('base64');

  // Determine media type from content type or key extension
  let mediaType = response.ContentType || 'image/jpeg';
  if (imageKey.toLowerCase().endsWith('.png')) {
    mediaType = 'image/png';
  } else if (imageKey.toLowerCase().endsWith('.webp')) {
    mediaType = 'image/webp';
  } else if (imageKey.toLowerCase().endsWith('.gif')) {
    mediaType = 'image/gif';
  }

  return { base64, mediaType };
}

/**
 * Delete image from S3 after processing
 */
async function deleteImageFromS3(imageKey: string): Promise<void> {
  const command = new DeleteObjectCommand({
    Bucket: BUCKET_NAME,
    Key: imageKey,
  });

  await s3Client.send(command);
}

/**
 * Call Claude API with vision to extract aisle data from image
 */
async function extractAisleDataWithClaude(base64Image: string, mediaType: string): Promise<ExtractedData> {
  const anthropic = new Anthropic({
    apiKey: ANTHROPIC_API_KEY,
  });

  const prompt = `Analyze this grocery store image. This could be:
- A store directory board listing many products and their aisle numbers
- An aisle sign showing what products are in that aisle
- Any store navigation aid

Extract ALL product-to-aisle mappings you can see. For store directories with tables/lists, extract EVERY row.

Return JSON only, no other text:
{
  "storeName": "Stop & Shop" (if visible, otherwise omit),
  "mappings": [
    { "product": "air freshener", "aisle": "19" },
    { "product": "aluminum foil", "aisle": "6" },
    { "product": "ammonia", "aisle": "18" },
    ... (continue for ALL visible products)
  ]
}

IMPORTANT:
- Extract EVERY product you can read from the image
- Use the exact aisle number/name shown (e.g., "19", "Meat", "Dairy", "Deli", "Produce")
- For product names, use lowercase and the exact text shown
- Do not summarize or skip products - extract the complete list
- If text is partially visible, include it with your best interpretation`;

  const response = await anthropic.messages.create({
    model: 'claude-sonnet-4-20250514',
    max_tokens: 16384,  // Increased for large directories
    temperature: 0,
    messages: [
      {
        role: 'user',
        content: [
          {
            type: 'image',
            source: {
              type: 'base64',
              media_type: mediaType as 'image/jpeg' | 'image/png' | 'image/webp' | 'image/gif',
              data: base64Image,
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

  // Extract text content from response
  const textContent = response.content.find((block) => block.type === 'text');
  if (!textContent || textContent.type !== 'text') {
    throw new Error('No text response from Claude');
  }

  // Parse JSON from response
  const jsonMatch = textContent.text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    throw new Error('No valid JSON found in Claude response');
  }

  const extractedData: ExtractedData = JSON.parse(jsonMatch[0]);

  // Validate structure
  if (!extractedData.mappings || !Array.isArray(extractedData.mappings)) {
    throw new Error('Invalid extraction result structure - missing mappings array');
  }

  return extractedData;
}

/**
 * Save extracted mappings to DynamoDB
 * For each product, generates multiple name variants and saves a mapping for each
 */
async function saveMappings(
  storeId: string,
  extractedData: ExtractedData,
  imageKey: string
): Promise<number> {
  const { mappings } = extractedData;
  const mappedAt = new Date().toISOString();
  let count = 0;

  for (const mapping of mappings) {
    const aisleId = mapping.aisle || 'Unknown';

    // Generate all name variants for this product
    const nameVariants = normalizeProductName(mapping.product);

    // Save a mapping for each variant
    for (const normalizedName of nameVariants) {
      // Create a unique ID based on storeId + variant to avoid conflicts
      const sanitizedVariant = normalizedName.replace(/[^a-z0-9]/g, '_');
      const id = `${storeId}_${sanitizedVariant}`;

      const item = {
        id,
        storeId,
        normalizedName,
        aisleId,
        confidence: 1.0, // Direct from image = high confidence
        source: 'IMAGE',
        reasoning: `Explicitly listed on store directory in aisle ${aisleId}`,
        sourceImageKeys: [imageKey],
        mappedAt,
        createdAt: mappedAt,
        updatedAt: mappedAt,
        __typename: 'ProductAisleMapping',
      };

      const command = new PutItemCommand({
        TableName: PRODUCT_AISLE_MAPPING_TABLE_NAME,
        Item: marshall(item, { removeUndefinedValues: true }),
      });

      await dynamoClient.send(command);
      count++;
    }
  }

  return count;
}

/**
 * Group flat mappings into aisle groups for UI display
 */
function groupMappingsByAisle(extractedData: ExtractedData): AisleGroup[] {
  const aisleMap = new Map<string, AisleGroup>();

  for (const mapping of extractedData.mappings) {
    const aisleId = mapping.aisle || 'Unknown';

    if (!aisleMap.has(aisleId)) {
      aisleMap.set(aisleId, {
        id: `aisle_${aisleId}`,
        number: aisleId,
        name: getAisleName(aisleId),
        products: [],
      });
    }

    const group = aisleMap.get(aisleId)!;
    group.products.push({
      id: `${aisleId}_${group.products.length}`,
      name: mapping.product,
      confidence: 'high',
    });
  }

  // Sort aisles: numeric first, then alphabetic
  return Array.from(aisleMap.values()).sort((a, b) => {
    const aNum = parseInt(a.number);
    const bNum = parseInt(b.number);
    if (!isNaN(aNum) && !isNaN(bNum)) return aNum - bNum;
    if (!isNaN(aNum)) return -1;
    if (!isNaN(bNum)) return 1;
    return a.number.localeCompare(b.number);
  });
}

/**
 * Normalize a product name and generate multiple search variants
 * e.g., "tomatoes-canned" → ["tomatoes canned", "canned tomatoes"]
 */
function normalizeProductName(name: string): string[] {
  // Base normalization: lowercase, trim, remove hyphens, collapse spaces
  const normalized = name
    .toLowerCase()
    .trim()
    .replace(/-/g, ' ')
    .replace(/\s+/g, ' ');

  const variants = new Set<string>();
  variants.add(normalized);

  // Split into words and generate reversed variant for multi-word names
  const words = normalized.split(' ').filter((w) => w.length > 0);
  if (words.length >= 2) {
    // Add reversed order variant (e.g., "tomatoes canned" → "canned tomatoes")
    const reversed = [...words].reverse().join(' ');
    variants.add(reversed);

    // For 3+ word phrases, also try common reorderings
    if (words.length === 3) {
      // e.g., "green beans canned" → "canned green beans"
      variants.add(`${words[2]} ${words[0]} ${words[1]}`);
      // e.g., "green beans canned" → "beans green canned" (less common but covers edge cases)
      variants.add(`${words[1]} ${words[0]} ${words[2]}`);
    }
  }

  return Array.from(variants);
}

/**
 * Get a readable name for common aisle types
 */
function getAisleName(aisleId: string): string {
  const specialAisles: Record<string, string> = {
    'Meat': 'Meat Department',
    'Deli': 'Deli Counter',
    'Dairy': 'Dairy Section',
    'Produce': 'Fresh Produce',
    'Bakery': 'Bakery',
    'Frozen': 'Frozen Foods',
    'Seafood': 'Seafood',
  };

  if (specialAisles[aisleId]) {
    return specialAisles[aisleId];
  }

  const num = parseInt(aisleId);
  if (!isNaN(num)) {
    return `Aisle ${num}`;
  }

  return aisleId;
}

export const handler = async (
  event: AppSyncResolverEvent<HandlerArguments>
): Promise<ExtractionResult> => {
  const { imageKey, storeId } = event.arguments;

  if (!imageKey || !storeId) {
    return {
      success: false,
      error: 'Missing required arguments: imageKey and storeId',
    };
  }

  try {
    // Step 1: Download image from S3
    console.log(`Downloading image: ${imageKey}`);
    const { base64, mediaType } = await downloadImageAsBase64(imageKey);

    // Step 2: Call Claude to extract aisle data
    console.log('Calling Claude API for extraction...');
    const extractedData = await extractAisleDataWithClaude(base64, mediaType);
    console.log(`Extracted ${extractedData.mappings.length} product mappings`);

    // Step 3: Save mappings to DynamoDB
    console.log('Saving mappings to DynamoDB...');
    const mappingsCreated = await saveMappings(storeId, extractedData, imageKey);

    // Step 4: Delete image from S3
    console.log(`Deleting processed image: ${imageKey}`);
    await deleteImageFromS3(imageKey);

    // Step 5: Group mappings by aisle for UI display
    const aisles = groupMappingsByAisle(extractedData);

    const result: ExtractionResult = {
      success: true,
      aisles,
      totalProducts: extractedData.mappings.length,
    };

    console.log(`Returning ${aisles.length} aisles with ${extractedData.mappings.length} total products`);
    return result;
  } catch (error) {
    console.error('Error extracting aisle mappings:', error);

    const result: ExtractionResult = {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error occurred',
    };

    return result;
  }
};
