import { S3Client, GetObjectCommand } from '@aws-sdk/client-s3';
import Anthropic from '@anthropic-ai/sdk';
import type { AppSyncResolverEvent } from 'aws-lambda';

const s3Client = new S3Client({});

const BUCKET_NAME = process.env.BUCKET_NAME!;
const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY!;

interface HandlerArguments {
  imageKeys: string[];
}

interface AisleEntry {
  productName: string;
  aisle: string;
}

interface ExtractResult {
  success: boolean;
  entries: AisleEntry[];
  imageCount: number;
  error?: string;
}

/**
 * Download image from S3 and convert to base64
 */
async function downloadImageAsBase64(imageKey: string): Promise<{ base64: string; mediaType: string }> {
  console.log(`[OCR] Downloading image: ${imageKey}`);

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
  const sizeMB = (buffer.length / (1024 * 1024)).toFixed(2);
  console.log(`[OCR] Downloaded image: ${sizeMB} MB`);

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
  console.log('[OCR] Calling Claude to extract aisle directory...');

  const prompt = `You are reading a grocery store aisle directory sign/board.

Extract ALL product-to-aisle mappings you can see in this image.

Return a JSON array with this structure:
[
  { "productName": "Canned Tomatoes", "aisle": "4" },
  { "productName": "Pasta", "aisle": "4" },
  { "productName": "Milk", "aisle": "Dairy" },
  ...
]

Rules:
- Extract EVERY item you can read from the directory
- Use the exact product names as written on the sign
- Use the exact aisle numbers/names as written
- If an aisle has multiple products, list each separately
- Include section names like "Dairy", "Produce", "Frozen" if used instead of numbers

Return ONLY the JSON array, no other text.`;

  const response = await anthropic.messages.create({
    model: 'claude-3-5-haiku-20241022',  // Haiku is faster for OCR tasks
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

  console.log(`[OCR] Claude response length: ${textContent.text.length} chars`);

  const jsonMatch = textContent.text.match(/\[[\s\S]*\]/);
  if (!jsonMatch) {
    console.error('[OCR] No JSON found in response:', textContent.text.substring(0, 500));
    throw new Error('No valid JSON array found in Claude response');
  }

  const entries: AisleEntry[] = JSON.parse(jsonMatch[0]);
  console.log(`[OCR] Extracted ${entries.length} aisle entries from image`);

  return entries;
}

export const handler = async (
  event: AppSyncResolverEvent<HandlerArguments>
): Promise<ExtractResult> => {
  const { imageKeys } = event.arguments;

  console.log(`[OCR] Starting extraction for ${imageKeys?.length || 0} images`);

  if (!imageKeys || imageKeys.length === 0) {
    return {
      success: false,
      entries: [],
      imageCount: 0,
      error: 'No images provided',
    };
  }

  try {
    const anthropic = new Anthropic({
      apiKey: ANTHROPIC_API_KEY,
    });

    // Process each image and combine results
    const allEntries: AisleEntry[] = [];
    const seenKeys = new Set<string>();

    for (let i = 0; i < imageKeys.length; i++) {
      const imageKey = imageKeys[i];
      console.log(`[OCR] Processing image ${i + 1}/${imageKeys.length}: ${imageKey}`);

      const image = await downloadImageAsBase64(imageKey);
      const entries = await extractFromImage(image, anthropic);

      // Deduplicate entries (same product + aisle)
      for (const entry of entries) {
        const key = `${entry.productName.toLowerCase()}|${entry.aisle}`;
        if (!seenKeys.has(key)) {
          seenKeys.add(key);
          allEntries.push(entry);
        }
      }
    }

    console.log(`[OCR] Total unique entries extracted: ${allEntries.length}`);

    return {
      success: true,
      entries: allEntries,
      imageCount: imageKeys.length,
    };
  } catch (error) {
    console.error('[OCR] Error:', error);
    return {
      success: false,
      entries: [],
      imageCount: imageKeys.length,
      error: error instanceof Error ? error.message : 'Unknown error',
    };
  }
};
