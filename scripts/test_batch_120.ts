#!/usr/bin/env npx ts-node

import Anthropic from '@anthropic-ai/sdk';

const MODEL = 'claude-3-5-haiku-latest';

// 120 products
const PRODUCTS = Array.from({ length: 120 }, (_, i) => ({
  id: `prod-${i}`,
  name: `Product ${i}`
}));

const AISLES = [
  { productName: "Canned Goods", aisle: "4" },
  { productName: "Pasta", aisle: "4" },
  { productName: "Rice", aisle: "5" },
  { productName: "Dairy", aisle: "Dairy" },
  { productName: "Frozen", aisle: "Frozen" },
];

async function main() {
  const anthropic = new Anthropic();

  const prompt = `Match these 120 products to aisles. Return JSON array with productId and aisleId only (no reasoning).

AISLES: ${JSON.stringify(AISLES)}

PRODUCTS: ${JSON.stringify(PRODUCTS)}

Return ONLY: [{"productId":"...","aisleId":"...","confidence":0.9}, ...]`;

  console.log('Testing 120 products in single batch...');
  const start = Date.now();

  const response = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 4096,
    messages: [{ role: 'user', content: prompt }],
  });

  const elapsed = Date.now() - start;

  const text = response.content.find(b => b.type === 'text');
  let count = 0;
  if (text && text.type === 'text') {
    const match = text.text.match(/\[[\s\S]*\]/);
    if (match) count = JSON.parse(match[0]).length;
  }

  console.log(`Time: ${(elapsed/1000).toFixed(1)}s`);
  console.log(`Products matched: ${count}`);
  console.log(`\nProjected for 239 products (2 parallel batches): ${(elapsed/1000).toFixed(1)}s`);
}

main().catch(console.error);
