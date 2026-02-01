#!/usr/bin/env npx ts-node

/**
 * Quick test script to benchmark OCR speed with Haiku vs Sonnet
 * Usage: ANTHROPIC_API_KEY=your_key npx ts-node scripts/test_ocr_speed.ts <image_path>
 */

import Anthropic from '@anthropic-ai/sdk';
import * as fs from 'fs';
import * as path from 'path';

const HAIKU = 'claude-3-5-haiku-latest';
const SONNET = 'claude-sonnet-4-5';

async function testOCR(imagePath: string, model: string): Promise<{ time: number; entries: number }> {
  const anthropic = new Anthropic();

  // Read image
  const imageBuffer = fs.readFileSync(imagePath);
  const base64 = imageBuffer.toString('base64');
  const ext = path.extname(imagePath).toLowerCase();
  const mediaType = ext === '.png' ? 'image/png' : 'image/jpeg';

  const prompt = `You are reading a grocery store aisle directory sign/board.

Extract ALL product-to-aisle mappings you can see in this image.

Return a JSON array with this structure:
[
  { "productName": "Canned Tomatoes", "aisle": "4" },
  { "productName": "Pasta", "aisle": "4" },
  ...
]

Rules:
- Extract EVERY item you can read from the directory
- Use the exact product names as written on the sign
- For aisle values: use ONLY the number or section name, NOT the word "Aisle"

Return ONLY the JSON array, no other text.`;

  const start = Date.now();

  const response = await anthropic.messages.create({
    model: model,
    max_tokens: 8192,
    messages: [
      {
        role: 'user',
        content: [
          {
            type: 'image',
            source: {
              type: 'base64',
              media_type: mediaType as 'image/jpeg' | 'image/png',
              data: base64,
            },
          },
          { type: 'text', text: prompt },
        ],
      },
    ],
  });

  const elapsed = Date.now() - start;

  // Parse response
  const textContent = response.content.find((b) => b.type === 'text');
  let entries = 0;
  if (textContent && textContent.type === 'text') {
    const jsonMatch = textContent.text.match(/\[[\s\S]*\]/);
    if (jsonMatch) {
      entries = JSON.parse(jsonMatch[0]).length;
    }
  }

  return { time: elapsed, entries };
}

async function main() {
  const imagePath = process.argv[2];

  if (!imagePath) {
    console.log('Usage: ANTHROPIC_API_KEY=xxx npx ts-node scripts/test_ocr_speed.ts <image_path>');
    console.log('\nExample: npx ts-node scripts/test_ocr_speed.ts ~/Downloads/store_directory.jpg');
    process.exit(1);
  }

  if (!fs.existsSync(imagePath)) {
    console.error(`File not found: ${imagePath}`);
    process.exit(1);
  }

  console.log(`\nTesting OCR speed with image: ${imagePath}\n`);
  console.log('='.repeat(50));

  // Test Haiku
  console.log(`\n🐦 Testing Haiku (${HAIKU})...`);
  const haiku = await testOCR(imagePath, HAIKU);
  console.log(`   Time: ${(haiku.time / 1000).toFixed(2)}s`);
  console.log(`   Entries extracted: ${haiku.entries}`);

  // Test Sonnet
  console.log(`\n🎵 Testing Sonnet (${SONNET})...`);
  const sonnet = await testOCR(imagePath, SONNET);
  console.log(`   Time: ${(sonnet.time / 1000).toFixed(2)}s`);
  console.log(`   Entries extracted: ${sonnet.entries}`);

  // Summary
  console.log('\n' + '='.repeat(50));
  console.log('\n📊 SUMMARY:');
  console.log(`   Haiku:  ${(haiku.time / 1000).toFixed(2)}s (${haiku.entries} entries)`);
  console.log(`   Sonnet: ${(sonnet.time / 1000).toFixed(2)}s (${sonnet.entries} entries)`);
  console.log(`   Speedup: ${(sonnet.time / haiku.time).toFixed(1)}x faster with Haiku`);
}

main().catch(console.error);
