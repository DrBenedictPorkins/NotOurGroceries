import { DynamoDBClient, QueryCommand, ScanCommand, PutItemCommand, BatchWriteItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import Anthropic from '@anthropic-ai/sdk';
import type { AppSyncResolverEvent } from 'aws-lambda';

const dynamoClient = new DynamoDBClient({});

const PRODUCT_TABLE_NAME = process.env.PRODUCT_TABLE_NAME!;
const PRODUCT_AISLE_MAPPING_TABLE_NAME = process.env.PRODUCT_AISLE_MAPPING_TABLE_NAME!;
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY!;

interface HandlerArguments {
  storeId: string;
}

interface ExistingMapping {
  normalizedName: string;
  aisleId: string;
  source: string;
}

interface Product {
  id: string;
  name: string;
  normalizedName: string;
  category: string;
}

interface AisleInfo {
  id: string;
  name: string;
  products: string[];
}

interface GeneratedMapping {
  productId: string;
  normalizedName: string;
  aisleId: string;
  confidence: number;
  reasoning: string;
  source: 'LLM_GUESS';
}

interface GenerationResult {
  success: boolean;
  stats?: {
    totalProducts: number;
    mappingsCreated: number;
    highConfidence: number;
    lowConfidence: number;
  };
  error?: string;
}

/**
 * Fetch all existing ProductAisleMappings for a store (from image extraction)
 */
async function fetchExistingMappings(storeId: string): Promise<ExistingMapping[]> {
  const mappings: ExistingMapping[] = [];
  let lastEvaluatedKey: Record<string, unknown> | undefined;

  do {
    const command = new QueryCommand({
      TableName: PRODUCT_AISLE_MAPPING_TABLE_NAME,
      IndexName: 'mappingsByStore',
      KeyConditionExpression: 'storeId = :storeId',
      ExpressionAttributeValues: marshall({
        ':storeId': storeId,
      }),
      ExclusiveStartKey: lastEvaluatedKey ? marshall(lastEvaluatedKey) : undefined,
    });

    const response = await dynamoClient.send(command);

    if (response.Items) {
      for (const item of response.Items) {
        const mapping = unmarshall(item);
        mappings.push({
          normalizedName: mapping.normalizedName as string,
          aisleId: mapping.aisleId as string,
          source: mapping.source as string,
        });
      }
    }

    lastEvaluatedKey = response.LastEvaluatedKey
      ? (unmarshall(response.LastEvaluatedKey) as Record<string, unknown>)
      : undefined;
  } while (lastEvaluatedKey);

  return mappings;
}

/**
 * Fetch all products from the community product list
 */
async function fetchAllProducts(): Promise<Product[]> {
  const products: Product[] = [];
  let lastEvaluatedKey: Record<string, unknown> | undefined;

  do {
    const command = new ScanCommand({
      TableName: PRODUCT_TABLE_NAME,
      ExclusiveStartKey: lastEvaluatedKey ? marshall(lastEvaluatedKey) : undefined,
    });

    const response = await dynamoClient.send(command);

    if (response.Items) {
      for (const item of response.Items) {
        const product = unmarshall(item);
        products.push({
          id: product.id as string,
          name: product.name as string,
          normalizedName: product.normalizedName as string,
          category: product.category as string,
        });
      }
    }

    lastEvaluatedKey = response.LastEvaluatedKey
      ? (unmarshall(response.LastEvaluatedKey) as Record<string, unknown>)
      : undefined;
  } while (lastEvaluatedKey);

  return products;
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

/**
 * Build aisle information from existing mappings
 */
function buildAisleInfo(mappings: ExistingMapping[]): AisleInfo[] {
  const aisleMap = new Map<string, AisleInfo>();

  for (const mapping of mappings) {
    const existing = aisleMap.get(mapping.aisleId);
    if (existing) {
      existing.products.push(mapping.normalizedName);
    } else {
      aisleMap.set(mapping.aisleId, {
        id: mapping.aisleId,
        name: getAisleName(mapping.aisleId),
        products: [mapping.normalizedName],
      });
    }
  }

  // Sort aisles: numeric first, then alphabetic
  return Array.from(aisleMap.values()).sort((a, b) => {
    const aNum = parseInt(a.id);
    const bNum = parseInt(b.id);
    if (!isNaN(aNum) && !isNaN(bNum)) return aNum - bNum;
    if (!isNaN(aNum)) return -1;
    if (!isNaN(bNum)) return 1;
    return a.id.localeCompare(b.id);
  });
}

/**
 * Call Claude API to generate mappings for all products
 */
async function generateMappingsWithClaude(
  aisleInfo: AisleInfo[],
  products: Product[],
  existingMappedNames: Set<string>
): Promise<GeneratedMapping[]> {
  const anthropic = new Anthropic({
    apiKey: ANTHROPIC_API_KEY,
  });

  // Filter out products that already have IMAGE mappings
  const productsToMap = products.filter(
    (p) => !existingMappedNames.has(p.normalizedName)
  );

  if (productsToMap.length === 0) {
    return [];
  }

  // Build the aisle layout description
  const aisleLayoutDescription = aisleInfo
    .map((aisle) => `Aisle ${aisle.id}: ${aisle.products.slice(0, 20).join(', ')}`)
    .join('\n');

  // Build the product list (batch in chunks to avoid token limits)
  const BATCH_SIZE = 100;
  const allMappings: GeneratedMapping[] = [];

  for (let i = 0; i < productsToMap.length; i += BATCH_SIZE) {
    const batch = productsToMap.slice(i, i + BATCH_SIZE);
    const productList = batch
      .map((p) => `- ${p.normalizedName} (category: ${p.category})`)
      .join('\n');

    const prompt = `You have a store's aisle layout based on extracted sign/directory data:

${aisleLayoutDescription}

Map EVERY product in this list to the most appropriate aisle:
${productList}

For each product, return a JSON array with objects containing:
- normalizedName: the product name (exactly as given)
- aisleId: best matching aisle ID from the layout above
- confidence: 0.0-1.0 (1.0 = very confident based on similar products in aisle, 0.7-0.9 = educated guess, <0.7 = uncertain)
- reasoning: Brief 1-sentence explanation for why this aisle

Guidelines:
- If a product is similar to items already in an aisle, assign it there with high confidence
- Consider product categories when making assignments
- If truly uncertain, use "Unknown" as aisleId with low confidence

Return ONLY valid JSON array, no other text:
[{"normalizedName": "...", "aisleId": "...", "confidence": 0.85, "reasoning": "..."}]`;

    const response = await anthropic.messages.create({
      model: 'claude-sonnet-4-20250514',
      max_tokens: 8192,
      temperature: 0,
      messages: [
        {
          role: 'user',
          content: prompt,
        },
      ],
    });

    // Extract text content from response
    const textContent = response.content.find((block) => block.type === 'text');
    if (!textContent || textContent.type !== 'text') {
      console.error('No text response from Claude for batch', i);
      continue;
    }

    // Parse JSON from response
    const jsonMatch = textContent.text.match(/\[[\s\S]*\]/);
    if (!jsonMatch) {
      console.error('No valid JSON array found in Claude response for batch', i);
      continue;
    }

    try {
      const batchMappings = JSON.parse(jsonMatch[0]) as Array<{
        normalizedName: string;
        aisleId: string;
        confidence: number;
        reasoning: string;
      }>;

      // Find productId for each mapping
      for (const mapping of batchMappings) {
        const product = batch.find((p) => p.normalizedName === mapping.normalizedName);
        if (product) {
          allMappings.push({
            productId: product.id,
            normalizedName: mapping.normalizedName,
            aisleId: mapping.aisleId,
            confidence: mapping.confidence,
            reasoning: mapping.reasoning,
            source: 'LLM_GUESS',
          });
        }
      }
    } catch (parseError) {
      console.error('Failed to parse Claude response for batch', i, parseError);
    }
  }

  return allMappings;
}

/**
 * Generate a deterministic ID for a mapping to enable upsert behavior.
 * Using storeId + normalizedName ensures re-running won't create duplicates.
 */
function generateMappingId(storeId: string, normalizedName: string): string {
  // Sanitize normalizedName for use in ID (remove special chars, replace spaces with underscores)
  const sanitized = normalizedName.toLowerCase().trim().replace(/[^a-z0-9]/g, '_');
  return `${storeId}_llm_${sanitized}`;
}

/**
 * Save generated mappings to DynamoDB
 */
async function saveMappings(
  storeId: string,
  mappings: GeneratedMapping[]
): Promise<{ saved: number; failed: number }> {
  const mappedAt = new Date().toISOString();
  let savedCount = 0;
  let failedCount = 0;

  // Use batch writes for efficiency
  const BATCH_SIZE = 25; // DynamoDB limit

  for (let i = 0; i < mappings.length; i += BATCH_SIZE) {
    const batch = mappings.slice(i, i + BATCH_SIZE);

    const putRequests = batch.map((mapping) => {
      // Use deterministic ID for upsert behavior - re-running won't create duplicates
      const id = generateMappingId(storeId, mapping.normalizedName);

      return {
        PutRequest: {
          Item: marshall(
            {
              id,
              storeId,
              productId: mapping.productId,
              normalizedName: mapping.normalizedName,
              aisleId: mapping.aisleId,
              confidence: mapping.confidence,
              source: mapping.source,
              reasoning: mapping.reasoning,
              mappedAt,
              createdAt: mappedAt,
              updatedAt: mappedAt,
              __typename: 'ProductAisleMapping',
            },
            { removeUndefinedValues: true }
          ),
        },
      };
    });

    const command = new BatchWriteItemCommand({
      RequestItems: {
        [PRODUCT_AISLE_MAPPING_TABLE_NAME]: putRequests,
      },
    });

    try {
      const response = await dynamoClient.send(command);

      // Check for unprocessed items
      const unprocessed = response.UnprocessedItems?.[PRODUCT_AISLE_MAPPING_TABLE_NAME]?.length ?? 0;
      savedCount += batch.length - unprocessed;

      if (unprocessed > 0) {
        console.warn(`Batch write had ${unprocessed} unprocessed items, retrying individually...`);
        // Retry unprocessed items individually
        for (const item of response.UnprocessedItems?.[PRODUCT_AISLE_MAPPING_TABLE_NAME] ?? []) {
          try {
            const putCommand = new PutItemCommand({
              TableName: PRODUCT_AISLE_MAPPING_TABLE_NAME,
              Item: item.PutRequest?.Item,
            });
            await dynamoClient.send(putCommand);
            savedCount++;
          } catch (retryError) {
            console.error('Failed to save unprocessed item:', retryError);
            failedCount++;
          }
        }
      }
    } catch (error) {
      console.error('Error in batch write:', error);
      // Fall back to individual writes
      for (const mapping of batch) {
        try {
          const id = generateMappingId(storeId, mapping.normalizedName);
          const putCommand = new PutItemCommand({
            TableName: PRODUCT_AISLE_MAPPING_TABLE_NAME,
            Item: marshall(
              {
                id,
                storeId,
                productId: mapping.productId,
                normalizedName: mapping.normalizedName,
                aisleId: mapping.aisleId,
                confidence: mapping.confidence,
                source: mapping.source,
                reasoning: mapping.reasoning,
                mappedAt,
                createdAt: mappedAt,
                updatedAt: mappedAt,
                __typename: 'ProductAisleMapping',
              },
              { removeUndefinedValues: true }
            ),
          });
          await dynamoClient.send(putCommand);
          savedCount++;
        } catch (individualError) {
          console.error('Error saving individual mapping:', individualError);
          failedCount++;
        }
      }
    }
  }

  return { saved: savedCount, failed: failedCount };
}

export const handler = async (
  event: AppSyncResolverEvent<HandlerArguments>
): Promise<GenerationResult> => {
  const { storeId } = event.arguments;

  if (!storeId) {
    return {
      success: false,
      error: 'Missing required argument: storeId',
    };
  }

  try {
    // Step 1: Fetch existing mappings (from image extraction)
    console.log(`Fetching existing mappings for store: ${storeId}`);
    const existingMappings = await fetchExistingMappings(storeId);
    console.log(`Found ${existingMappings.length} existing mappings`);

    // Build set of already mapped product names (from IMAGE source)
    const existingMappedNames = new Set(
      existingMappings
        .filter((m) => m.source === 'IMAGE')
        .map((m) => m.normalizedName)
    );

    // Step 2: Build aisle information from existing mappings
    const aisleInfo = buildAisleInfo(existingMappings.filter((m) => m.source === 'IMAGE'));
    console.log(`Built info for ${aisleInfo.length} aisles`);

    if (aisleInfo.length === 0) {
      return {
        success: false,
        error: 'No aisle information found. Please extract aisles from store images first.',
      };
    }

    // Step 3: Fetch all community products
    console.log('Fetching community products...');
    const products = await fetchAllProducts();
    console.log(`Found ${products.length} products`);

    // Step 4: Call Claude to generate mappings
    console.log('Generating mappings with Claude...');
    const generatedMappings = await generateMappingsWithClaude(
      aisleInfo,
      products,
      existingMappedNames
    );
    console.log(`Generated ${generatedMappings.length} new mappings`);

    // Step 5: Save mappings to DynamoDB
    console.log('Saving mappings to DynamoDB...');
    const { saved: savedCount, failed: failedCount } = await saveMappings(storeId, generatedMappings);

    if (failedCount > 0) {
      console.warn(`${failedCount} mappings failed to save`);
    }

    // Calculate stats
    const highConfidence = generatedMappings.filter((m) => m.confidence >= 0.7).length;
    const lowConfidence = generatedMappings.filter((m) => m.confidence < 0.7).length;

    const result: GenerationResult = {
      success: true,
      stats: {
        totalProducts: products.length,
        mappingsCreated: savedCount,
        highConfidence,
        lowConfidence,
      },
    };

    console.log(`Successfully saved ${savedCount} mappings (${failedCount} failed)`);
    return result;
  } catch (error) {
    console.error('Error generating full mappings:', error);

    const result: GenerationResult = {
      success: false,
      error: error instanceof Error ? error.message : 'Unknown error occurred',
    };

    return result;
  }
};
