import { DynamoDBClient, QueryCommand, ScanCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import type { Schema } from '../resource';
import { requireHousehold } from '../requireHousehold';

const client = new DynamoDBClient({});

const PRODUCT_TABLE_NAME = process.env.PRODUCT_TABLE_NAME!;

type Handler = Schema['searchProducts']['functionHandler'];

interface ProductWithScore {
  product: Record<string, unknown>;
  score: number;
}

/**
 * Calculate Levenshtein distance between two strings
 */
function levenshteinDistance(str1: string, str2: string): number {
  const len1 = str1.length;
  const len2 = str2.length;
  const matrix: number[][] = [];

  for (let i = 0; i <= len1; i++) {
    matrix[i] = [i];
  }
  for (let j = 0; j <= len2; j++) {
    matrix[0][j] = j;
  }

  for (let i = 1; i <= len1; i++) {
    for (let j = 1; j <= len2; j++) {
      const cost = str1[i - 1] === str2[j - 1] ? 0 : 1;
      matrix[i][j] = Math.min(
        matrix[i - 1][j] + 1,
        matrix[i][j - 1] + 1,
        matrix[i - 1][j - 1] + cost
      );
    }
  }

  return matrix[len1][len2];
}

/**
 * Calculate similarity score between 0 and 1
 */
function calculateSimilarity(query: string, target: string): number {
  const distance = levenshteinDistance(query, target);
  const maxLength = Math.max(query.length, target.length);

  if (maxLength === 0) return 1;

  const similarity = 1 - (distance / maxLength);

  if (query === target) return 1.0;
  if (target.startsWith(query)) return 0.95;
  if (target.includes(query)) return Math.max(similarity, 0.85);

  return similarity;
}

/**
 * Check if product aliases match the query
 */
function checkAliases(aliases: string[] | null | undefined, normalizedQuery: string): number {
  if (!aliases || aliases.length === 0) return 0;

  let bestScore = 0;
  for (const alias of aliases) {
    const normalizedAlias = alias.toLowerCase().trim();
    const score = calculateSimilarity(normalizedQuery, normalizedAlias);
    bestScore = Math.max(bestScore, score);
  }

  return bestScore;
}

/**
 * Normalize query for matching
 * - Lowercase and trim
 * - Remove articles (a, an, the)
 * - Handle common plurals
 */
function normalizeQuery(name: string): string {
  let normalized = name.toLowerCase().trim();

  // Remove leading articles
  normalized = normalized.replace(/^(a |an |the )/i, '');

  // Handle common plural patterns
  if (normalized.endsWith('ies') && normalized.length > 4) {
    normalized = normalized.slice(0, -3) + 'y';
  } else if (normalized.endsWith('oes') && normalized.length > 4) {
    normalized = normalized.slice(0, -2);
  } else if (normalized.endsWith('es') && normalized.length > 3 &&
             !['cheese', 'rice'].includes(normalized)) {
    const stem = normalized.slice(0, -2);
    if (stem.endsWith('sh') || stem.endsWith('ch') || stem.endsWith('x') ||
        stem.endsWith('s') || stem.endsWith('z')) {
      normalized = stem;
    } else if (normalized.endsWith('ves')) {
      normalized = normalized.slice(0, -3) + 'f';
    }
  } else if (normalized.endsWith('s') && normalized.length > 2 &&
             !['hummus', 'asparagus', 'couscous', 'citrus'].includes(normalized)) {
    normalized = normalized.slice(0, -1);
  }

  return normalized.trim();
}

export const handler: Handler = async (event) => {
  requireHousehold(event);
  const { query, limit: inputLimit } = event.arguments;
  const limit = inputLimit ?? 10;

  // Also try matching with normalized (singular) form
  const normalizedQuery = normalizeQuery(query);
  const rawQuery = query.toLowerCase().trim();

  if (!normalizedQuery) {
    return [];
  }

  try {
    let results: ProductWithScore[] = [];

    // Step 1: Try exact match on normalizedName
    const exactMatchCommand = new QueryCommand({
      TableName: PRODUCT_TABLE_NAME,
      IndexName: 'productsByNormalizedName',
      KeyConditionExpression: 'normalizedName = :query',
      ExpressionAttributeValues: marshall({
        ':query': normalizedQuery,
      }),
      Limit: limit,
    });

    const exactMatchResponse = await client.send(exactMatchCommand);

    if (exactMatchResponse.Items && exactMatchResponse.Items.length > 0) {
      results = exactMatchResponse.Items.map((item) => ({
        product: unmarshall(item),
        score: 1.0,
      }));
    }

    // Step 2: If no exact matches, try prefix match (begins_with)
    if (results.length === 0) {
      const prefixMatchCommand = new QueryCommand({
        TableName: PRODUCT_TABLE_NAME,
        IndexName: 'productsByNormalizedName',
        KeyConditionExpression: 'begins_with(normalizedName, :prefix)',
        ExpressionAttributeValues: marshall({
          ':prefix': normalizedQuery,
        }),
        Limit: limit * 2,
      });

      const prefixMatchResponse = await client.send(prefixMatchCommand);

      if (prefixMatchResponse.Items && prefixMatchResponse.Items.length > 0) {
        results = prefixMatchResponse.Items.map((item) => {
          const product = unmarshall(item);
          return {
            product,
            score: calculateSimilarity(normalizedQuery, product.normalizedName as string),
          };
        });
      }
    }

    // Step 3: If still no results, do fuzzy scan
    if (results.length === 0) {
      const scanCommand = new ScanCommand({
        TableName: PRODUCT_TABLE_NAME,
        Limit: 100,
      });

      const scanResponse = await client.send(scanCommand);

      if (scanResponse.Items && scanResponse.Items.length > 0) {
        results = scanResponse.Items.map((item) => {
          const product = unmarshall(item);
          const nameScore = calculateSimilarity(normalizedQuery, product.normalizedName as string);
          const aliasScore = checkAliases(product.aliases as string[] | undefined, normalizedQuery);
          const score = Math.max(nameScore, aliasScore);

          return {
            product,
            score,
          };
        }).filter((result) => result.score >= 0.3);
      }
    }

    // Sort by score (highest first) and limit results
    const sortedResults = results
      .sort((a, b) => b.score - a.score)
      .slice(0, limit)
      .map((result) => result.product);

    return sortedResults as unknown as Schema['Product']['type'][];
  } catch (error) {
    console.error('Error searching products:', error);
    throw new Error(`Failed to search products: ${error instanceof Error ? error.message : 'Unknown error'}`);
  }
};
