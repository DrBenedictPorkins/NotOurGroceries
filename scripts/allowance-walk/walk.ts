/**
 * Walk a synthetic household through the allowance logic against the live
 * table. Uses an id no real household can have, touches nothing else, and
 * deletes its row at the end.
 */
// Table name comes from the environment: ALLOWANCE_TABLE_NAME=HouseholdAllowance-<api>-NONE

import { DynamoDBClient, UpdateItemCommand, GetItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall } from '@aws-sdk/util-dynamodb';
import {
  loadAllowance, checkAllowance, spend, setEntitlement, deleteAllowanceRow,
  summarize, CAPS, EXHAUSTED_PREFIX, PERIOD_MS,
} from '../../amplify/data/allowance';

const ddb = new DynamoDBClient({});
const TABLE = process.env.ALLOWANCE_TABLE_NAME!;
const id = `allowance-walk-${Date.now()}`;
const results: string[] = [];

function check(name: string, ok: boolean, detail = '') {
  results.push(`${ok ? 'PASS' : 'FAIL'}  ${name}${detail ? '  — ' + detail : ''}`);
}

async function refused(kind: 'placements' | 'parses'): Promise<boolean> {
  try { await checkAllowance(id, kind); return false; }
  catch (e: any) { return e.message === `${EXHAUSTED_PREFIX}${kind}`; }
}

(async () => {
  // 1. Fresh household
  let row = await loadAllowance(id);
  check('fresh row is FREE with zero counters', row.entitlement === 'FREE' && row.placementsThisPeriod === 0 && row.parsesThisPeriod === 0);
  const firstStart = row.periodStartedAt;

  // 2. Soft cap on placements
  await checkAllowance(id, 'placements');
  await spend(id, 'placements', 60, 'tester');
  check('60 spent, still allowed', !(await refused('placements')));
  await spend(id, 'placements', 55, 'tester');           // the trip that crosses the line is served in full
  row = await loadAllowance(id);
  check('overshoot recorded, not clipped', row.placementsThisPeriod === 115, `used=${row.placementsThisPeriod}`);
  check('next request refused with the prefix', await refused('placements'));
  check('parses untouched by placements', !(await refused('parses')));

  // 3. Parses
  await spend(id, 'parses', 1); await spend(id, 'parses', 1); await spend(id, 'parses', 1);
  check('3 parses then refused', await refused('parses'));

  // 4. Entitlement
  await setEntitlement(id, 'COMPED');
  check('COMPED passes over the cap', !(await refused('placements')) && !(await refused('parses')));
  await setEntitlement(id, 'FREE');
  check('back to FREE refuses again', await refused('placements'));
  await setEntitlement(id, 'SUBSCRIBED', new Date(Date.now() - 60_000).toISOString());
  check('lapsed subscription is FREE', await refused('placements'));
  await setEntitlement(id, 'SUBSCRIBED', new Date(Date.now() + 86_400_000).toISOString());
  check('live subscription passes', !(await refused('placements')));
  await setEntitlement(id, 'FREE');

  // 5. Period roll: backdate the start by 31 days, then look
  const backdated = new Date(new Date(firstStart).getTime() - 31 * 86_400_000).toISOString();
  await ddb.send(new UpdateItemCommand({
    TableName: TABLE, Key: marshall({ id }),
    UpdateExpression: 'SET periodStartedAt = :p', ExpressionAttributeValues: marshall({ ':p': backdated }),
  }));
  row = await loadAllowance(id);
  const expectedStart = new Date(new Date(backdated).getTime() + PERIOD_MS).toISOString();
  check('period rolled forward exactly one step', row.periodStartedAt === expectedStart, `${backdated} -> ${row.periodStartedAt}`);
  check('counters zeroed on roll', row.placementsThisPeriod === 0 && row.parsesThisPeriod === 0);
  check('allowed again after roll', !(await refused('placements')) && !(await refused('parses')));
  const s = summarize(row);
  check('summary caps match constants', s.placementsCap === CAPS.placements && s.parsesCap === CAPS.parses && s.membersCap === CAPS.members && s.itemsCap === CAPS.items);
  check('resets in the future, within 30 days', new Date(s.periodResetsAt) > new Date() && new Date(s.periodResetsAt).getTime() - Date.now() <= PERIOD_MS);

  // 6. Cleanup
  await deleteAllowanceRow(id);
  const gone = await ddb.send(new GetItemCommand({ TableName: TABLE, Key: marshall({ id }) }));
  check('row deleted', !gone.Item);

  console.log('\n' + results.join('\n'));
  console.log(`\n${results.filter(r => r.startsWith('PASS')).length}/${results.length} passed`);
})().catch((e) => { console.error('WALK FAILED', e); process.exit(1); });
