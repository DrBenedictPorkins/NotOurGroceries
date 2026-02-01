#!/usr/bin/env npx ts-node

/**
 * Test matching speed (Phase 2) - text only, no image upload
 */

import Anthropic from '@anthropic-ai/sdk';

const HAIKU = 'claude-3-5-haiku-latest';
const SONNET = 'claude-sonnet-4-5';

// Sample aisle entries (like what OCR extracts)
const SAMPLE_AISLES = [
  { productName: "Canned Tomatoes", aisle: "4" },
  { productName: "Pasta", aisle: "4" },
  { productName: "Rice", aisle: "5" },
  { productName: "Cereal", aisle: "6" },
  { productName: "Bread", aisle: "Bakery" },
  { productName: "Milk", aisle: "Dairy" },
  { productName: "Cheese", aisle: "Dairy" },
  { productName: "Yogurt", aisle: "Dairy" },
  { productName: "Frozen Pizza", aisle: "Frozen" },
  { productName: "Ice Cream", aisle: "Frozen" },
];

// Sample products to match (batch of 50)
const SAMPLE_PRODUCTS = Array.from({ length: 50 }, (_, i) => ({
  id: `prod-${i}`,
  name: [
    "Tomato Sauce", "Spaghetti", "Brown Rice", "Corn Flakes", "Whole Wheat Bread",
    "2% Milk", "Cheddar Cheese", "Greek Yogurt", "Pepperoni Pizza", "Vanilla Ice Cream",
    "Olive Oil", "Salt", "Pepper", "Sugar", "Flour",
    "Butter", "Eggs", "Bacon", "Orange Juice", "Apple Juice",
    "Coffee", "Tea", "Cookies", "Crackers", "Chips",
    "Salsa", "Tortillas", "Beans", "Soup", "Tuna",
    "Peanut Butter", "Jelly", "Honey", "Maple Syrup", "Ketchup",
    "Mustard", "Mayo", "Ranch Dressing", "BBQ Sauce", "Hot Sauce",
    "Paper Towels", "Toilet Paper", "Dish Soap", "Laundry Detergent", "Trash Bags",
    "Chicken Breast", "Ground Beef", "Salmon", "Shrimp", "Tofu"
  ][i % 50]
}));

async function testMatching(model: string): Promise<{ time: number; mappings: number }> {
  const anthropic = new Anthropic();

  const aisleDirectory = SAMPLE_AISLES.map(e => `- "${e.productName}" -> Aisle ${e.aisle}`).join('\n');
  const productList = JSON.stringify(SAMPLE_PRODUCTS, null, 2);

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

IMPORTANT: Map EVERY product - do not skip any. Return ONLY the JSON array.`;

  const start = Date.now();

  const response = await anthropic.messages.create({
    model: model,
    max_tokens: 4096,
    messages: [{ role: 'user', content: prompt }],
  });

  const elapsed = Date.now() - start;

  // Parse response
  const textContent = response.content.find((b) => b.type === 'text');
  let mappings = 0;
  if (textContent && textContent.type === 'text') {
    const jsonMatch = textContent.text.match(/\[[\s\S]*\]/);
    if (jsonMatch) {
      mappings = JSON.parse(jsonMatch[0]).length;
    }
  }

  return { time: elapsed, mappings };
}

async function main() {
  console.log(`\nTesting MATCHING speed (Phase 2) - 50 products, text-only\n`);
  console.log('='.repeat(50));

  // Test Haiku
  console.log(`\n🐦 Testing Haiku (${HAIKU})...`);
  const haiku = await testMatching(HAIKU);
  console.log(`   Time: ${(haiku.time / 1000).toFixed(2)}s`);
  console.log(`   Products matched: ${haiku.mappings}`);

  // Test Sonnet
  console.log(`\n🎵 Testing Sonnet (${SONNET})...`);
  const sonnet = await testMatching(SONNET);
  console.log(`   Time: ${(sonnet.time / 1000).toFixed(2)}s`);
  console.log(`   Products matched: ${sonnet.mappings}`);

  // Summary
  console.log('\n' + '='.repeat(50));
  console.log('\n📊 SUMMARY (Phase 2 - Matching):');
  console.log(`   Haiku:  ${(haiku.time / 1000).toFixed(2)}s (${haiku.mappings} products)`);
  console.log(`   Sonnet: ${(sonnet.time / 1000).toFixed(2)}s (${sonnet.mappings} products)`);
  console.log(`   Speedup: ${(sonnet.time / haiku.time).toFixed(1)}x faster with Haiku`);

  console.log('\n📈 PROJECTED FULL JOB (5 batches × 50 products):');
  console.log(`   Haiku:  ${((haiku.time * 5) / 1000).toFixed(0)}s (~${((haiku.time * 5) / 60000).toFixed(1)} min)`);
  console.log(`   Sonnet: ${((sonnet.time * 5) / 1000).toFixed(0)}s (~${((sonnet.time * 5) / 60000).toFixed(1)} min)`);
}

main().catch(console.error);
