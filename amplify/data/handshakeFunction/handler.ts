import { logEvent, logWarning, logFailure } from '../telemetry';
import { DynamoDBClient, GetItemCommand, QueryCommand, ScanCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import { requireHousehold } from '../requireHousehold';
import { loadAllowance, summarize } from '../allowance';
import type { Schema } from '../resource';

const client = new DynamoDBClient({});

const USER_TABLE_NAME = process.env.USER_TABLE_NAME!;
const HOUSEHOLD_TABLE_NAME = process.env.HOUSEHOLD_TABLE_NAME!;
const GROCERY_ITEM_TABLE_NAME = process.env.GROCERY_ITEM_TABLE_NAME!;
const HOUSEHOLD_STORE_TABLE_NAME = process.env.HOUSEHOLD_STORE_TABLE_NAME!;
const PRODUCT_TABLE_NAME = process.env.PRODUCT_TABLE_NAME!;

type Handler = Schema['handshake']['functionHandler'];

/**
 * Everything the app needs to be usable, in one call.
 *
 * Launch used to be eight round trips — profile, catalogue, members, items,
 * stores, household, allowances, device — each with its own deadline, its own
 * failure and its own way of being half-done. On a good connection nobody
 * noticed. On a bad one they landed one at a time over the following minute, on
 * top of a screen somebody was already using, and any one of them could fail
 * while the rest succeeded, leaving the app assembled from a mixture of what
 * loaded and what didn't.
 *
 * One call has one answer. It either populated the app or it didn't, and the
 * "didn't" is a single branch — which is what makes off-grid a decision rather
 * than an eight-way guess.
 *
 * Deliberately NOT here: aisle mappings. They are per store × per product, 639KB
 * across the table today and growing, and they are not on the launch path — the
 * store screen fetches the one store it needs. Folding them in would put the
 * largest and least-used payload on the critical path.
 */
export const handler: Handler = async (event) => {
  const identity = (event as { identity?: { sub?: string } }).identity;
  const userId = identity?.sub;
  if (!userId) throw new Error('Not signed in.');

  const households = requireHousehold(event);
  const { deviceId } = event.arguments;

  const user = await readUser(userId);
  const householdId: string | undefined = user?.householdId;

  // No household yet — onboarding. Answer what we can rather than throwing; the
  // app needs to know it has no household, which is a fact and not a failure.
  if (!householdId) {
    return json({
      user: user ?? null,
      household: null,
      members: [],
      items: [],
      stores: [],
      allowances: null,
      products: await readProducts(),
      device: deviceState(user, deviceId),
    });
  }

  if (!households.includes(householdId)) {
    // The row says one household, the token says another. Trust the token —
    // the row is what a removed member's stale client would still be holding.
    logWarning('handshake.householdMismatch', { userId });
  }

  // In parallel. They touch different tables and none depends on another, so
  // the wall-clock cost is the slowest one rather than the sum.
  const [household, members, items, stores, products, allowance] = await Promise.all([
    readHousehold(householdId),
    readMembers(householdId),
    readItems(householdId),
    readStores(householdId),
    readProducts(),
    loadAllowance(householdId).catch((error) => {
      logFailure('handshake.allowanceFailed', error, { householdId });
      return null;
    }),
  ]);

  logEvent('handshake.served', {
    householdId,
    items: items.length,
    members: members.length,
    stores: stores.length,
    products: products.length,
  });

  return json({
    user: user ?? null,
    household,
    members,
    items,
    stores,
    allowances: allowance ? summarize(allowance) : null,
    products,
    device: deviceState(user, deviceId),
  });
};

/**
 * Whether this device still holds the account.
 *
 * Folded in here rather than left as its own call: it is asked at exactly the
 * same moments, and a device that has been superseded should not be told so a
 * round trip after it has already rebuilt the whole screen.
 */
export function deviceState(user: Record<string, any> | null, deviceId?: string | null) {
  const held: string | undefined = user?.activeDeviceId;
  // No registration means an account that has not claimed since this shipped.
  // Held, rather than evicting everybody on upgrade.
  const stillOurs = !held || !deviceId || held === deviceId;
  return {
    stillOurs,
    activeDeviceName: stillOurs ? null : (user?.activeDeviceName ?? null),
  };
}

/// AppSync hands `AWSJSON` back as a string.
function json(payload: unknown): string {
  return JSON.stringify(payload);
}

// MARK: - Reads

async function readUser(userId: string) {
  const result = await client.send(new GetItemCommand({
    TableName: USER_TABLE_NAME,
    Key: marshall({ id: userId }),
  }));
  return result.Item ? unmarshall(result.Item) : null;
}

async function readHousehold(householdId: string) {
  const result = await client.send(new GetItemCommand({
    TableName: HOUSEHOLD_TABLE_NAME,
    Key: marshall({ id: householdId }),
  }));
  return result.Item ? unmarshall(result.Item) : null;
}

async function readMembers(householdId: string) {
  return queryAll(USER_TABLE_NAME, 'usersByHouseholdId', 'householdId', householdId);
}

async function readItems(householdId: string) {
  return queryAll(
    GROCERY_ITEM_TABLE_NAME,
    'groceryItemsByHouseholdIdAndStatus',
    'householdId',
    householdId,
  );
}

async function readStores(householdId: string) {
  return queryAll(
    HOUSEHOLD_STORE_TABLE_NAME,
    'householdStoresByHouseholdId',
    'householdId',
    householdId,
  );
}

/**
 * The product catalogue: global, static, 239 rows and 48KB today.
 *
 * Sent every launch on purpose. A new client build does not imply a new server
 * deployment and the reverse is just as true, so the only way a phone learns
 * about catalogue changes is by asking. At this size that is cheaper than any
 * scheme for deciding whether to ask.
 *
 * A Scan is correct here and nowhere else in this codebase: there is no
 * partition to query by, because the whole table is the answer.
 */
async function readProducts() {
  const out: Record<string, any>[] = [];
  let lastKey: Record<string, any> | undefined;
  do {
    const page = await client.send(new ScanCommand({
      TableName: PRODUCT_TABLE_NAME,
      ProjectionExpression: 'id, #n, normalizedName, category, aliases',
      ExpressionAttributeNames: { '#n': 'name' },
      ExclusiveStartKey: lastKey,
    }));
    for (const item of page.Items ?? []) out.push(unmarshall(item));
    lastKey = page.LastEvaluatedKey;
  } while (lastKey);
  return out;
}

async function queryAll(table: string, index: string, keyName: string, keyValue: string) {
  const out: Record<string, any>[] = [];
  let lastKey: Record<string, any> | undefined;
  do {
    const page = await client.send(new QueryCommand({
      TableName: table,
      IndexName: index,
      KeyConditionExpression: '#k = :v',
      ExpressionAttributeNames: { '#k': keyName },
      ExpressionAttributeValues: marshall({ ':v': keyValue }),
      ExclusiveStartKey: lastKey,
    }));
    for (const item of page.Items ?? []) out.push(unmarshall(item));
    lastKey = page.LastEvaluatedKey;
  } while (lastKey);
  return out;
}
