/**
 * Aisle placement bake-off: Sonnet against Haiku, judged by eye.
 *
 * `inferProductAisle` is the app's one piece of real judgement, and it degrades
 * quietly — a worse model does not throw, it just sends somebody to the wrong
 * end of the shop. So the question "can this run on Haiku" cannot be answered
 * from a benchmark; it needs placements from both models, side by side, against
 * a real store's layout, with a person reading them.
 *
 * This drives the production prompt (imported, not copied) over a fixed list of
 * products in batches of five, exactly as the app does, and writes an HTML
 * report. The reference column was written by Opus against the same aisle list
 * before either model was run.
 *
 * Run: ANTHROPIC_API_KEY=... npx tsx scripts/aisle-bakeoff/run.ts
 */
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, ScanCommand } from '@aws-sdk/lib-dynamodb';
import Anthropic from '@anthropic-ai/sdk';
import { readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  buildAisleContext,
  canonicalAisleId,
  inferAisleBatch,
  type StoreAisle,
  type ExistingMapping,
} from '../../amplify/data/inferProductAisleFunction/handler';

const HERE = dirname(fileURLToPath(import.meta.url));
const SUFFIX = '-vdsfrt2plzgwfdae2ucpxtwzh4-NONE';
const STORE_TABLE = `HouseholdStore${SUFFIX}`;
const MAPPING_TABLE = `ProductAisleMapping${SUFFIX}`;

const MODELS = [
  { key: 'sonnet', id: 'claude-sonnet-4-6', inPrice: 3, outPrice: 15 },
  { key: 'haiku', id: 'claude-haiku-4-5', inPrice: 1, outPrice: 5 },
] as const;

const BATCH_SIZE = 5;

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({ region: 'us-east-1' }));

interface TestItem { name: string; ref: string; hard?: string }

/**
 * What the store's own directory says, where it says anything.
 *
 * A sign-derived row is better ground truth than a reference placement written
 * by a model that shares its priors with the two under test. Where the sign
 * names the product outright that value is the answer; the reference column
 * only stands in where the directory is silent. The `reasoning` field on an
 * IMAGE row records the sign text verbatim, which is what makes this readable.
 */
function signTruth(raw: any[]): Map<string, string> {
  const out = new Map<string, string>();
  for (const r of raw) {
    if (r.source !== 'IMAGE') continue;
    // `IMAGE` alone is not enough: rows like `frozen pizza -> Frozen` carry that
    // source but a reasoning of "belongs in frozen section", which is a guess
    // wearing the label. Only a verbatim directory line is ground truth, and
    // only when the stored name still matches what was read.
    const quoted = /^Directly listed on store sign: "(.+?)"$/.exec((r.reasoning ?? '').trim());
    if (!quoted) continue;
    const name = (r.normalizedName ?? '').trim().toLowerCase();
    if (name && quoted[1].trim().toLowerCase() === name) out.set(name, r.aisleId);
  }
  return out;
}
interface Placement { aisle: string; confidence: number; reasoning: string }

async function loadAisles(storeId: string): Promise<StoreAisle[]> {
  const result = await ddb.send(new GetCommand({ TableName: STORE_TABLE, Key: { id: storeId } }));
  const raw = result.Item?.aisleLayout;
  const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
  return (parsed ?? []) as StoreAisle[];
}

const rawRows: any[] = [];

async function loadMappings(storeId: string): Promise<ExistingMapping[]> {
  const out: ExistingMapping[] = [];
  // Scan rather than query the by-store index: the developer credentials this
  // script runs under can read the table but not that GSI, and the whole table
  // is ~1,250 rows.
  let last: Record<string, unknown> | undefined;
  do {
    const page = await ddb.send(new ScanCommand({
      TableName: MAPPING_TABLE,
      FilterExpression: 'storeId = :s',
      ExpressionAttributeValues: { ':s': storeId },
      ExclusiveStartKey: last,
    }));
    for (const m of page.Items ?? []) {
      out.push({ aisleId: m.aisleId, normalizedName: m.normalizedName, confidence: m.confidence });
      rawRows.push(m);
    }
    last = page.LastEvaluatedKey;
  } while (last);
  return out;
}

/**
 * Expand the shorthand in items.json. `A7` means aisle 7 of this store, whose
 * real id carries the store uuid; the standard departments are already literal.
 */
function expandRef(ref: string, storeId: string): string {
  return /^A\d+$/.test(ref) ? `aisle-${storeId}-${ref.slice(1)}` : ref;
}

function label(aisleId: string, aisles: StoreAisle[]): string {
  const a = aisles.find((x) => x.id === aisleId);
  if (!a) return aisleId === 'Unknown' || !aisleId ? '—' : aisleId;
  return [a.number, a.name].filter(Boolean).join(' ').trim() || a.id;
}

async function placeAll(
  items: TestItem[],
  context: string,
  anthropic: Anthropic,
  model: string
): Promise<{ placements: Map<string, Placement>; inTokens: number; outTokens: number }> {
  const placements = new Map<string, Placement>();
  let inTokens = 0;
  let outTokens = 0;

  for (let i = 0; i < items.length; i += BATCH_SIZE) {
    const batch = items.slice(i, i + BATCH_SIZE);
    const { results, usage } = await inferAisleBatch(
      batch.map((it) => ({ productName: it.name, normalizedName: it.name.toLowerCase() })),
      context,
      anthropic,
      model
    );
    inTokens += usage.input_tokens;
    outTokens += usage.output_tokens;

    // The model echoes the product name back; match on it rather than on order,
    // and fall back to position so a reworded echo still lands somewhere.
    for (const [j, item] of batch.entries()) {
      const hit = results.find((r) => r.productName?.toLowerCase() === item.name.toLowerCase()) ?? results[j];
      placements.set(item.name, {
        aisle: hit?.aisle ?? 'Unknown',
        confidence: hit?.confidence ?? 0,
        reasoning: hit?.reasoning ?? '',
      });
    }
    process.stderr.write(`  ${model}: ${Math.min(i + BATCH_SIZE, items.length)}/${items.length}\n`);
  }
  return { placements, inTokens, outTokens };
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
}

async function main() {
  const spec = JSON.parse(readFileSync(join(HERE, 'items.json'), 'utf8'));
  const storeId: string = spec.store;
  const items: TestItem[] = spec.items;

  const [aisles, allMappings] = await Promise.all([loadAisles(storeId), loadMappings(storeId)]);

  // Any test product that already has a mapping would appear in the context as
  // its own answer. Strip those, or both models score full marks for reading.
  const underTest = new Set(items.map((i) => i.name.toLowerCase()));
  const mappings = allMappings.filter((m) => !underTest.has((m.normalizedName ?? '').trim().toLowerCase()));
  const withheld = allMappings.length - mappings.length;

  const context = buildAisleContext(mappings, aisles);
  console.error(`${aisles.length} aisles, ${mappings.length} mappings as context (${withheld} withheld as answers)`);

  const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY! });
  const runs = [];
  for (const m of MODELS) {
    console.error(`running ${m.id}…`);
    const r = await placeAll(items, context, anthropic, m.id);
    const cost = (r.inTokens / 1e6) * m.inPrice + (r.outTokens / 1e6) * m.outPrice;
    runs.push({ ...m, ...r, cost });
  }

  const [sonnet, haiku] = runs;
  const sign = signTruth(rawRows);
  const canon = (a: string) => canonicalAisleId(a, aisles);

  const rows = items.map((item) => {
    const signed = sign.get(item.name.toLowerCase());
    const truth = canon(signed ?? expandRef(item.ref, storeId));
    const s = sonnet.placements.get(item.name)!;
    const h = haiku.placements.get(item.name)!;
    return {
      item,
      truth,
      truthSource: signed ? 'sign' : 'opus',
      ref: canon(expandRef(item.ref, storeId)),
      s,
      h,
      sMatch: canon(s.aisle) === truth,
      hMatch: canon(h.aisle) === truth,
      agree: canon(s.aisle) === canon(h.aisle),
    };
  });

  // Disagreements first — those are the only rows worth a person's attention.
  const ordered = [...rows].sort((a, b) => {
    const rank = (r: typeof a) => (!r.agree ? 0 : !r.sMatch || !r.hMatch ? 1 : 2);
    return rank(a) - rank(b);
  });

  const summary = {
    total: rows.length,
    agree: rows.filter((r) => r.agree).length,
    sonnetMatch: rows.filter((r) => r.sMatch).length,
    haikuMatch: rows.filter((r) => r.hMatch).length,
    hardTotal: rows.filter((r) => r.item.hard).length,
    hardSonnet: rows.filter((r) => r.item.hard && r.sMatch).length,
    hardHaiku: rows.filter((r) => r.item.hard && r.hMatch).length,
    signTotal: rows.filter((r) => r.truthSource === 'sign').length,
    signSonnet: rows.filter((r) => r.truthSource === 'sign' && r.sMatch).length,
    signHaiku: rows.filter((r) => r.truthSource === 'sign' && r.hMatch).length,
    refDiffers: rows.filter((r) => r.truthSource === 'sign' && r.ref !== r.truth).length,
  };

  const html = renderReport({ spec, aisles, rows: ordered, summary, sonnet, haiku, withheld, mappingCount: mappings.length });
  const out = join(HERE, 'report.html');
  writeFileSync(out, html);
  writeFileSync(join(HERE, 'report.json'), JSON.stringify({ summary, rows: ordered }, null, 2));

  console.error('');
  console.error(`agree on ${summary.agree}/${summary.total}`);
  console.error(`vs reference — sonnet ${summary.sonnetMatch}, haiku ${summary.haikuMatch}`);
  console.error(`ambiguous only  — sonnet ${summary.hardSonnet}/${summary.hardTotal}, haiku ${summary.hardHaiku}/${summary.hardTotal}`);
  console.error(`sign-verified   — sonnet ${summary.signSonnet}/${summary.signTotal}, haiku ${summary.signHaiku}/${summary.signTotal} (${summary.refDiffers} contradict the Opus reference)`);
  console.error(`cost — sonnet $${sonnet.cost.toFixed(4)}, haiku $${haiku.cost.toFixed(4)}`);
  console.error(`\n${out}`);
}

function renderReport(d: any): string {
  const { spec, aisles, rows, summary, sonnet, haiku, withheld, mappingCount } = d;
  const cell = (p: Placement, match: boolean) => `
      <td class="place ${match ? 'ok' : 'off'}">
        <span class="aisle">${escapeHtml(label(p.aisle, aisles))}</span>
        <span class="conf">${p.confidence.toFixed(2)}</span>
        <span class="why">${escapeHtml(p.reasoning)}</span>
      </td>`;

  const body = rows.map((r: any, i: number) => `
    <tr class="${!r.agree ? 'split' : r.sMatch && r.hMatch ? 'clean' : 'both-off'}">
      <td class="pick"><input type="checkbox" data-item="${escapeHtml(r.item.name)}" id="c${i}"><label for="c${i}"></label></td>
      <td class="name">
        ${escapeHtml(r.item.name)}
        ${r.item.hard ? `<span class="hard" title="${escapeHtml(r.item.hard)}">ambiguous</span>` : ''}
      </td>
      <td class="ref">${escapeHtml(label(r.truth, aisles))}<span class="src ${r.truthSource}">${r.truthSource === 'sign' ? 'sign' : 'judged'}</span>${
        r.truthSource === 'sign' && r.ref !== r.truth ? `<span class="was">Opus said ${escapeHtml(label(r.ref, aisles))}</span>` : ''}</td>
      ${cell(r.s, r.sMatch)}
      ${cell(r.h, r.hMatch)}
      <td class="verdict">${!r.agree ? 'split' : r.sMatch ? 'both&nbsp;match' : 'both&nbsp;differ'}</td>
    </tr>`).join('');

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Aisle Model Bake-off</title>
<style>
  :root {
    --ground: #fbfaf8; --panel: #fff; --ink: #1b1a17; --muted: #6b675f;
    --line: #e3ded4; --ok: #2f6b46; --off: #a8442a; --split: #b8791f;
    --okbg: #eef5f0; --offbg: #fbf0ec; --splitbg: #fdf6e9;
  }
  @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
    --ground: #16151300; --ground: #161513; --panel: #1e1d1a; --ink: #eceae5; --muted: #9a948a;
    --line: #34322d; --ok: #7fc79c; --off: #e39075; --split: #e0b364;
    --okbg: #1b2721; --offbg: #2a1e19; --splitbg: #29231733;
  } }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--ground); color: var(--ink);
    font: 15px/1.5 ui-sans-serif, -apple-system, "Segoe UI", sans-serif; }
  .wrap { max-width: 1180px; margin: 0 auto; padding: 40px 24px 80px; }
  h1 { font-size: 26px; margin: 0 0 6px; letter-spacing: -0.01em; }
  .sub { color: var(--muted); margin: 0 0 28px; }
  .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
    gap: 12px; margin-bottom: 28px; }
  .stat { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 14px 16px; }
  .stat b { display: block; font-size: 24px; font-variant-numeric: tabular-nums; font-weight: 600; }
  .stat span { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: .06em; }
  .scroll { overflow-x: auto; border: 1px solid var(--line); border-radius: 8px; background: var(--panel); }
  table { border-collapse: collapse; width: 100%; min-width: 900px; }
  th { text-align: left; font-size: 11px; text-transform: uppercase; letter-spacing: .07em;
    color: var(--muted); padding: 12px 10px; border-bottom: 1px solid var(--line); font-weight: 600; }
  td { padding: 10px; border-bottom: 1px solid var(--line); vertical-align: top; }
  tr.split { background: var(--splitbg); }
  tr.both-off { background: var(--offbg); }
  .name { font-weight: 600; }
  .hard { display: inline-block; margin-left: 6px; font-size: 10px; font-weight: 500;
    text-transform: uppercase; letter-spacing: .05em; color: var(--split);
    border: 1px solid currentColor; border-radius: 3px; padding: 1px 5px; cursor: help; }
  .ref { color: var(--muted); }
  .src { display: block; font-size: 10px; text-transform: uppercase; letter-spacing: .05em; margin-top: 2px; }
  .src.sign { color: var(--ok); }
  .src.opus { color: var(--muted); }
  .was { display: block; font-size: 11px; color: var(--split); margin-top: 2px; }
  .aisle { display: block; font-weight: 600; }
  .place.ok .aisle { color: var(--ok); }
  .place.off .aisle { color: var(--off); }
  .conf { font-size: 11px; color: var(--muted); font-variant-numeric: tabular-nums; }
  .why { display: block; font-size: 12px; color: var(--muted); margin-top: 2px; }
  .verdict { font-size: 12px; color: var(--muted); white-space: nowrap; }
  .pick { width: 34px; }
  .bar { position: sticky; bottom: 0; margin-top: 20px; background: var(--panel);
    border: 1px solid var(--line); border-radius: 8px; padding: 12px 16px;
    display: flex; align-items: center; gap: 14px; }
  button { font: inherit; font-size: 13px; padding: 7px 14px; border-radius: 6px;
    border: 1px solid var(--line); background: var(--ground); color: var(--ink); cursor: pointer; }
  #out { width: 100%; margin-top: 12px; min-height: 90px; font: 12px/1.5 ui-monospace, monospace;
    background: var(--ground); color: var(--ink); border: 1px solid var(--line);
    border-radius: 6px; padding: 10px; }
  footer { color: var(--muted); font-size: 12px; margin-top: 28px; }
</style></head><body><div class="wrap">
<h1>Aisle Model Bake-off</h1>
<p class="sub">${escapeHtml(spec.storeName)} · ${aisles.length} aisles · ${mappingCount} existing mappings as context
  (${withheld} withheld because they name a product under test) · batches of ${BATCH_SIZE} · temperature 0</p>

<div class="stats">
  <div class="stat"><b>${summary.agree}/${summary.total}</b><span>models agree</span></div>
  <div class="stat"><b>${summary.sonnetMatch}/${summary.total}</b><span>Sonnet vs reference</span></div>
  <div class="stat"><b>${summary.haikuMatch}/${summary.total}</b><span>Haiku vs reference</span></div>
  <div class="stat"><b>${summary.hardSonnet}/${summary.hardTotal} · ${summary.hardHaiku}/${summary.hardTotal}</b><span>ambiguous only, S · H</span></div>
  <div class="stat"><b>${summary.signSonnet}/${summary.signTotal} · ${summary.signHaiku}/${summary.signTotal}</b><span>sign-verified only, S · H</span></div>
  <div class="stat"><b>$${sonnet.cost.toFixed(4)}</b><span>Sonnet run</span></div>
  <div class="stat"><b>$${haiku.cost.toFixed(4)}</b><span>Haiku run</span></div>
</div>

<div class="scroll"><table>
<thead><tr><th></th><th>Item</th><th>Answer</th><th>Sonnet</th><th>Haiku</th><th></th></tr></thead>
<tbody>${body}</tbody>
</table></div>

<div class="bar">
  <button id="copy">Copy ticked items</button>
  <span class="verdict" id="count">none ticked</span>
</div>
<textarea id="out" placeholder="Tick the rows you think are wrong, then Copy — paste the result back into the session."></textarea>

<footer>Rows marked <b>sign</b> are answered by the store's own directory — objective, and withheld from the prompt.
Rows marked <b>judged</b> have no directory entry; those fall back to a reference placement Opus wrote before either model ran.
${summary.refDiffers} of the sign-answered rows contradict that reference, which is why the sign column exists.
Where all three agree the row proves little; the split rows are the ones worth reading.
Rows are ordered: disagreements, then rows where both models differ from the reference, then the rest.</footer>
</div>
<script>
  const boxes = () => [...document.querySelectorAll('input[type=checkbox]')];
  const refresh = () => {
    const on = boxes().filter(b => b.checked);
    document.getElementById('count').textContent = on.length ? on.length + ' ticked' : 'none ticked';
  };
  document.addEventListener('change', refresh);
  document.getElementById('copy').addEventListener('click', () => {
    const lines = boxes().filter(b => b.checked).map(b => {
      const tr = b.closest('tr'), c = tr.querySelectorAll('td');
      return '- ' + b.dataset.item + ' — ref ' + c[2].innerText.trim()
        + ' | sonnet ' + c[3].querySelector('.aisle').innerText.trim()
        + ' | haiku ' + c[4].querySelector('.aisle').innerText.trim();
    });
    document.getElementById('out').value = lines.join('\\n');
  });
  refresh();
</script>
</body></html>`;
}

main().catch((e) => { console.error(e); process.exit(1); });
