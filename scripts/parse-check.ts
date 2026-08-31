/**
 * Run the parse prompt against saved fixtures, without deploying.
 *
 * Prompt work needs a fast loop. Going through Amplify means a push to main, a
 * deploy, and a device to test on — minutes per attempt, on production, with no
 * record of what the previous wording produced. This does the same call the
 * Lambda does and prints the result.
 *
 * It imports the real prompt from `amplify/data/parseIngredientsFunction/prompt.ts`.
 * A copied-out duplicate would start drifting immediately and you would be tuning
 * something that is not what ships.
 *
 * Usage:
 *   load-secrets                       # ANTHROPIC_API_KEY must be in the environment
 *   npx tsx scripts/parse-check.ts             # every fixture
 *   npx tsx scripts/parse-check.ts pasty       # fixtures whose name contains "pasty"
 *   npx tsx scripts/parse-check.ts --json      # raw JSON instead of the table
 *
 * Fixtures live in scripts/parse-fixtures/:
 *   *.txt         parsed as text (a pasted recipe, a dictated transcript, a list)
 *   *.png, *.jpg  parsed as an image (a screenshot of a recipe)
 *   *.terms       optional, one product name per line, sharing a fixture's base
 *                 name — stands in for the household catalog
 */

import Anthropic from '@anthropic-ai/sdk';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, extname, basename, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  MODEL,
  buildRules,
  buildMessageContent,
  cleanItems,
  type ParsedIngredient,
} from '../amplify/data/parseIngredientsFunction/prompt';

const HERE = dirname(fileURLToPath(import.meta.url));
const FIXTURES = join(HERE, 'parse-fixtures');

const IMAGE_EXT = new Set(['.png', '.jpg', '.jpeg']);
const TEXT_EXT = new Set(['.txt', '.md']);

function loadTerms(fixturePath: string): string[] {
  const termsPath = fixturePath.replace(extname(fixturePath), '.terms');
  if (!existsSync(termsPath)) return [];
  return readFileSync(termsPath, 'utf8')
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean);
}

async function run(anthropic: Anthropic, file: string) {
  const path = join(FIXTURES, file);
  const ext = extname(file).toLowerCase();
  const isImage = IMAGE_EXT.has(ext);

  const content = buildMessageContent(
    isImage
      ? { imageData: readFileSync(path).toString('base64') }
      : { rawText: readFileSync(path, 'utf8') }
  );

  const started = Date.now();
  const response = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 1024,
    temperature: 0,
    system: [
      { type: 'text', text: buildRules(loadTerms(path)), cache_control: { type: 'ephemeral' } },
    ],
    messages: [{ role: 'user', content }],
  });
  const elapsed = Date.now() - started;

  const block = response.content.find((b) => b.type === 'text');
  const text = block && block.type === 'text' ? block.text : '';
  const match = text.match(/\[[\s\S]*\]/);

  if (!match) {
    return { file, elapsed, usage: response.usage, items: null as ParsedIngredient[] | null, text };
  }

  return {
    file,
    elapsed,
    usage: response.usage,
    items: cleanItems(JSON.parse(match[0])),
    text,
  };
}

function render(result: Awaited<ReturnType<typeof run>>) {
  const { file, elapsed, usage, items, text } = result;

  console.log(`\n\x1b[1m${file}\x1b[0m  ${elapsed}ms`);
  // A cache read of 0 on a second run means something volatile is in the prefix.
  console.log(
    `  tokens  in ${usage.input_tokens}  cache-read ${usage.cache_read_input_tokens ?? 0}` +
      `  cache-write ${usage.cache_creation_input_tokens ?? 0}  out ${usage.output_tokens}`
  );

  if (!items) {
    console.log(`  \x1b[31mno JSON array in response\x1b[0m`);
    console.log(`  ${text.slice(0, 300)}`);
    return;
  }

  if (items.length === 0) {
    console.log('  (no items)');
    return;
  }

  for (const item of items) {
    const flags = [
      item.staple ? '\x1b[33mstaple\x1b[0m' : '',
      item.needsInput ? '\x1b[36mneeds-input\x1b[0m' : '',
      item.alternatives?.length ? `alt: ${item.alternatives.join(' / ')}` : '',
      item.heardAs ? `heard: "${item.heardAs}"` : '',
    ].filter(Boolean);

    const name = item.qualifier ? `${item.name} · ${item.qualifier}` : item.name;

    console.log(`  ${name}${flags.length ? `   ${flags.join('  ')}` : ''}`);
  }
}

async function main() {
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) {
    console.error('ANTHROPIC_API_KEY is not set. Run `load-secrets` first.');
    process.exit(1);
  }

  const args = process.argv.slice(2);
  const asJson = args.includes('--json');
  const filters = args.filter((a) => !a.startsWith('--'));

  if (!existsSync(FIXTURES)) {
    console.error(`No fixtures directory at ${FIXTURES}`);
    process.exit(1);
  }

  const files = readdirSync(FIXTURES)
    .filter((f) => IMAGE_EXT.has(extname(f).toLowerCase()) || TEXT_EXT.has(extname(f).toLowerCase()))
    .filter((f) => filters.length === 0 || filters.some((q) => basename(f).includes(q)))
    .sort();

  if (files.length === 0) {
    console.error('No matching fixtures. Drop a recipe screenshot or a .txt into scripts/parse-fixtures/');
    process.exit(1);
  }

  const anthropic = new Anthropic({ apiKey: key });

  // Sequential on purpose: the first call writes the prompt cache and the rest
  // read it, which is also what the cache numbers are worth watching for.
  const results: Awaited<ReturnType<typeof run>>[] = [];
  for (const file of files) {
    results.push(await run(anthropic, file));
  }

  if (asJson) {
    console.log(JSON.stringify(results.map((r) => ({ file: r.file, items: r.items })), null, 2));
    return;
  }

  results.forEach(render);
  console.log('');
}

main().catch((error) => {
  // Never print the client object; it carries the key.
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
