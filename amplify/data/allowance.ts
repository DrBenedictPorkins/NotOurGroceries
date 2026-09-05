import {
  DynamoDBClient,
  GetItemCommand,
  PutItemCommand,
  UpdateItemCommand,
  DeleteItemCommand,
} from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import { logEvent, logWarning } from './telemetry';

/**
 * Allowances — how much a free household may do, and what it has done.
 *
 * The design is in `MONETIZATION.qmd`. The short version: every feature works on
 * the free tier, only the volume differs; the caps are soft, so a request that
 * starts with allowance left is served in full and the balance floors at zero;
 * the period rolls from the household, thirty days at a time, not from the
 * calendar; and entitlement is per household, so a shared pool.
 *
 * Counters live on their own row, `HouseholdAllowance`, keyed by household id,
 * rather than on `Household`. Members can update `Household` from the client —
 * it is their row — and a counter or an entitlement flag anyone in the household
 * can write is not a limit. The allowance row is readable by the household and
 * written only from here, over IAM.
 */

const client = new DynamoDBClient({});
const TABLE = process.env.ALLOWANCE_TABLE_NAME!;

/**
 * The free caps. The one place these numbers exist server-side; the client
 * learns them from `householdAllowances` and never hardcodes one.
 *
 * `items` is enforced on the client only — items are written straight through
 * `createGroceryItem`, there is no Lambda to refuse in — and lives here so the
 * app has one source for the number. See the doc for why that was accepted.
 */
export const CAPS = {
  placements: 100,
  parses: 3,
  members: 2,
  items: 150,
} as const;

export const PERIOD_MS = 30 * 24 * 60 * 60 * 1000;

export type Metered = 'placements' | 'parses';
export type Entitlement = 'FREE' | 'SUBSCRIBED' | 'COMPED';

/**
 * The client looks for this prefix on an error and renders its own copy, so
 * the wording lives in one place per screen rather than being shipped from here.
 * What follows the colon is the allowance that ran out.
 */
export const EXHAUSTED_PREFIX = 'ALLOWANCE_EXHAUSTED:';

export interface AllowanceRow {
  id: string;
  groupName: string;
  entitlement: Entitlement;
  subscriptionExpiresAt?: string;
  periodStartedAt: string;
  placementsThisPeriod: number;
  parsesThisPeriod: number;
  createdAt: string;
  updatedAt: string;
}

const COUNTER: Record<Metered, keyof AllowanceRow> = {
  placements: 'placementsThisPeriod',
  parses: 'parsesThisPeriod',
};

function freshRow(householdId: string, now: Date): AllowanceRow {
  const iso = now.toISOString();
  return {
    id: householdId,
    groupName: householdId,
    entitlement: 'FREE',
    periodStartedAt: iso,
    placementsThisPeriod: 0,
    parsesThisPeriod: 0,
    createdAt: iso,
    updatedAt: iso,
  };
}

/**
 * Create the row for a household that has none. Idempotent: two callers racing
 * on a household's first metered action both end up with the one row.
 *
 * Called when a household is created, and lazily from `loadAllowance` for the
 * households that predate this table — their period starts at their first
 * metered action rather than at creation, which is the same thing to within a
 * few minutes for anyone new and irrelevant for anyone old.
 */
export async function ensureAllowanceRow(householdId: string, now = new Date()): Promise<void> {
  try {
    await client.send(new PutItemCommand({
      TableName: TABLE,
      Item: marshall({ ...freshRow(householdId, now), __typename: 'HouseholdAllowance' }),
      ConditionExpression: 'attribute_not_exists(id)',
    }));
  } catch (error: unknown) {
    if ((error as { name?: string }).name !== 'ConditionalCheckFailedException') throw error;
  }
}

async function getRow(householdId: string): Promise<AllowanceRow | null> {
  const result = await client.send(new GetItemCommand({
    TableName: TABLE,
    Key: marshall({ id: householdId }),
  }));
  return result.Item ? (unmarshall(result.Item) as AllowanceRow) : null;
}

/**
 * The start of the period `now` falls in, given when the household's first one
 * began. Steps forward thirty days at a time, so a household nobody touched for
 * three months rolls straight to the current period rather than through each.
 */
function currentPeriodStart(firstStart: string, now: Date): Date {
  const first = new Date(firstStart).getTime();
  const elapsed = Math.max(0, now.getTime() - first);
  const periods = Math.floor(elapsed / PERIOD_MS);
  return new Date(first + periods * PERIOD_MS);
}

export function periodResetsAt(row: AllowanceRow, now = new Date()): Date {
  return new Date(currentPeriodStart(row.periodStartedAt, now).getTime() + PERIOD_MS);
}

/**
 * Load the household's row, creating it if missing and rolling the period
 * forward if it has lapsed. There is no scheduled reset; the roll happens the
 * first time anyone looks after the boundary.
 *
 * The roll is conditional on the old `periodStartedAt`, so two Lambdas crossing
 * the boundary together zero the counters once, not twice.
 */
export async function loadAllowance(householdId: string, now = new Date()): Promise<AllowanceRow> {
  let row = await getRow(householdId);
  if (!row) {
    await ensureAllowanceRow(householdId, now);
    row = (await getRow(householdId))!;
  }

  const start = currentPeriodStart(row.periodStartedAt, now);
  if (start.toISOString() === row.periodStartedAt) return row;

  try {
    const result = await client.send(new UpdateItemCommand({
      TableName: TABLE,
      Key: marshall({ id: householdId }),
      UpdateExpression: 'SET periodStartedAt = :start, placementsThisPeriod = :zero, parsesThisPeriod = :zero, updatedAt = :now',
      ConditionExpression: 'periodStartedAt = :old',
      ExpressionAttributeValues: marshall({
        ':start': start.toISOString(),
        ':old': row.periodStartedAt,
        ':zero': 0,
        ':now': now.toISOString(),
      }),
      ReturnValues: 'ALL_NEW',
    }));
    logEvent('allowance.periodRolled', { householdId, from: row.periodStartedAt, to: start.toISOString() });
    return unmarshall(result.Attributes!) as AllowanceRow;
  } catch (error: unknown) {
    if ((error as { name?: string }).name !== 'ConditionalCheckFailedException') throw error;
    // Somebody else rolled it between our read and our write. Theirs is right.
    return (await getRow(householdId))!;
  }
}

/** Subscribed and not lapsed, or comped. A lapsed subscription is just FREE. */
export function isEntitled(row: AllowanceRow, now = new Date()): boolean {
  if (row.entitlement === 'COMPED') return true;
  if (row.entitlement === 'SUBSCRIBED') {
    return !row.subscriptionExpiresAt || new Date(row.subscriptionExpiresAt) > now;
  }
  return false;
}

export function used(row: AllowanceRow, kind: Metered): number {
  return (row[COUNTER[kind]] as number | undefined) ?? 0;
}

/**
 * Refuse if a free household has nothing left of this allowance.
 *
 * Soft cap: the question is only whether the balance is above zero. A caller
 * that passes is served in full however large the request, and `spend` takes
 * the balance below zero if it must; the next caller is the one refused. Returns
 * the row so the caller can log where the household stands.
 */
export async function checkAllowance(householdId: string, kind: Metered): Promise<AllowanceRow> {
  const row = await loadAllowance(householdId);
  if (isEntitled(row)) return row;

  const remaining = CAPS[kind] - used(row, kind);
  if (remaining <= 0) {
    logWarning('allowance.refused', { householdId, kind, used: used(row, kind), cap: CAPS[kind] });
    throw new Error(`${EXHAUSTED_PREFIX}${kind}`);
  }
  return row;
}

/**
 * Record what was just done. Called after the work succeeds, not before, so a
 * Claude call that failed is not charged to anybody. Atomic `ADD`, so two
 * concurrent spends both count. Entitled households are counted too — that is
 * what tells us what a paying household actually costs.
 */
export async function spend(householdId: string, kind: Metered, n: number, spentBy?: string): Promise<void> {
  if (n <= 0) return;
  const result = await client.send(new UpdateItemCommand({
    TableName: TABLE,
    Key: marshall({ id: householdId }),
    UpdateExpression: `ADD #counter :n SET updatedAt = :now`,
    ExpressionAttributeNames: { '#counter': COUNTER[kind] },
    ExpressionAttributeValues: marshall({ ':n': n, ':now': new Date().toISOString() }),
    ReturnValues: 'ALL_NEW',
  }));
  const row = unmarshall(result.Attributes!) as AllowanceRow;
  logEvent('allowance.spent', {
    householdId, kind, n,
    used: used(row, kind), cap: CAPS[kind],
    entitlement: row.entitlement,
    // Who spent it, for "is one person doing all the mapping" — attribution,
    // not a separate budget. See the doc.
    spentBy: spentBy ?? null,
  });
}

export async function setEntitlement(
  householdId: string,
  entitlement: Entitlement,
  subscriptionExpiresAt?: string,
): Promise<AllowanceRow> {
  await ensureAllowanceRow(householdId);
  const result = await client.send(new UpdateItemCommand({
    TableName: TABLE,
    Key: marshall({ id: householdId }),
    UpdateExpression: subscriptionExpiresAt
      ? 'SET entitlement = :e, subscriptionExpiresAt = :exp, updatedAt = :now'
      : 'SET entitlement = :e, updatedAt = :now REMOVE subscriptionExpiresAt',
    ExpressionAttributeValues: marshall(
      subscriptionExpiresAt
        ? { ':e': entitlement, ':exp': subscriptionExpiresAt, ':now': new Date().toISOString() }
        : { ':e': entitlement, ':now': new Date().toISOString() },
    ),
    ReturnValues: 'ALL_NEW',
  }));
  logEvent('allowance.entitlementSet', { householdId, entitlement });
  return unmarshall(result.Attributes!) as AllowanceRow;
}

export async function deleteAllowanceRow(householdId: string): Promise<void> {
  await client.send(new DeleteItemCommand({ TableName: TABLE, Key: marshall({ id: householdId }) }));
}

/** What the app shows. Flat, so the Swift side decodes it without ceremony. */
export interface AllowanceSummary {
  entitlement: Entitlement;
  entitled: boolean;
  periodResetsAt: string;
  placementsUsed: number;
  placementsCap: number;
  parsesUsed: number;
  parsesCap: number;
  membersCap: number;
  itemsCap: number;
}

export function summarize(row: AllowanceRow, now = new Date()): AllowanceSummary {
  return {
    entitlement: row.entitlement,
    entitled: isEntitled(row, now),
    periodResetsAt: periodResetsAt(row, now).toISOString(),
    placementsUsed: used(row, 'placements'),
    placementsCap: CAPS.placements,
    parsesUsed: used(row, 'parses'),
    parsesCap: CAPS.parses,
    membersCap: CAPS.members,
    itemsCap: CAPS.items,
  };
}
