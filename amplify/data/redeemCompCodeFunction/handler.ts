import { logEvent, logWarning, logFailure } from '../telemetry';
import { DynamoDBClient, UpdateItemCommand, ScanCommand } from '@aws-sdk/client-dynamodb';
import { marshall } from '@aws-sdk/util-dynamodb';
import { requireHousehold } from '../requireHousehold';
import { codeFor } from '../../auth/customMessageFunction/handler';
import { loadAllowance, isEntitled, setEntitlement } from '../allowance';
import type { Schema } from '../resource';

const client = new DynamoDBClient({});

const COMP_CODE_TABLE_NAME = process.env.COMP_CODE_TABLE_NAME!;

/** How many households get comped. The cap is on redemption, which is the thing
 *  that actually costs anything. */
export const FOUNDER_COMP_LIMIT = 100;

type Handler = Schema['redeemCompCode']['functionHandler'];

/**
 * "Install, enter the code, get comped. Done."
 *
 * The first hundred households arrive through an unlisted listing and a code
 * typed into the app. The cap *is* the table: exactly a hundred rows are minted,
 * so a hundred-and-first code cannot be redeemed because it does not exist.
 * There is no counter anywhere, and therefore no race to lose.
 *
 * Codes are unique rather than one shared string. A single string posted
 * publicly would be spent by everyone or by nobody, and one person could burn
 * every slot in a minute.
 *
 * The comp is permanent and it applies to the household, not the person —
 * entitlement already works that way, so a second member joins by invite and
 * inherits it without spending a second code.
 */
export const handler: Handler = async (event) => {
  const households = requireHousehold(event);
  const householdId = households[0];
  const code = normalize(event.arguments.code);

  const identity = (event as { identity?: { claims?: Record<string, unknown> } }).identity;
  const email = String(identity?.claims?.email ?? '');
  if (!email) {
    logWarning('comp.rejected', { reason: 'no_email_claim' });
    return { status: 'INVALID', message: "We couldn't read your account's email address." };
  }

  if (!code) {
    return { status: 'INVALID', message: "That doesn't look like a code. Check it and try again." };
  }

  // Refuse before recording anything. Somebody already comped, or paying,
  // redeeming a code would take a slot out of the hundred and get nothing.
  const allowance = await loadAllowance(householdId);
  if (isEntitled(allowance)) {
    logEvent('comp.alreadyEntitled', { householdId, entitlement: allowance.entitlement });
    return {
      status: 'ALREADY_ENTITLED',
      message: allowance.entitlement === 'COMPED'
        ? "Your household is already comped — no code needed."
        : "Your household already has a subscription, so there's nothing to redeem.",
    };
  }

  // The code is an HMAC of the address it was mailed to, recomputed here from
  // the caller's own token. No list of codes exists to be stolen, and a code
  // that leaks is worth nothing to whoever finds it — they cannot sign in as the
  // address it belongs to.
  if (codeFor(email) !== code) {
    logWarning('comp.codeInvalid', { householdId });
    return { status: 'INVALID', message: "That code isn't for this account. Check it and try again." };
  }

  // Claim it. The row is keyed by the code, so this is also what makes it
  // single-use: a second household typing the same code loses the condition.
  try {
    await client.send(new UpdateItemCommand({
      TableName: COMP_CODE_TABLE_NAME,
      Key: marshall({ code }),
      UpdateExpression:
        'SET redeemedByHouseholdId = :hid, redeemedAt = :now, issuedToEmail = :e, '
        + 'createdAt = if_not_exists(createdAt, :now), updatedAt = :now, #t = :type',
      ConditionExpression: 'attribute_not_exists(redeemedByHouseholdId)',
      ExpressionAttributeNames: { '#t': '__typename' },
      ExpressionAttributeValues: marshall({
        ':hid': householdId,
        ':e': email.trim().toLowerCase(),
        ':now': new Date().toISOString(),
        ':type': 'CompCode',
      }),
    }));
  } catch (error) {
    if (isConditionFailure(error)) {
      logWarning('comp.codeSpent', { householdId });
      return {
        status: 'SPENT',
        message: "That code has already been used. Everything still works — you're on the free plan.",
      };
    }
    logFailure('comp.claimFailed', error, { householdId });
    throw error;
  }

  // The cap, checked after the claim so the row that proves it exists. Over the
  // limit, the claim stands as a record and the household stays free — better a
  // spent code with no comp than a comp with no record of who has one.
  if (!(await underCap())) {
    logWarning('comp.overCap', { householdId });
    return {
      status: 'SPENT',
      message: "The first hundred places have all gone. Everything still works — you're on the free plan.",
    };
  }

  await setEntitlement(householdId, 'COMPED');
  logEvent('comp.redeemed', { householdId });

  return {
    status: 'COMPED',
    message: "Done — your household's limits are lifted for good.",
  };
};

/**
 * How many codes have been redeemed. A Scan over at most a hundred rows, which
 * is the cap: an index to avoid reading a hundred items would cost more to keep
 * than the read it saves.
 */
async function underCap(): Promise<boolean> {
  let redeemed = 0;
  let lastKey: Record<string, any> | undefined;
  do {
    const page = await client.send(new ScanCommand({
      TableName: COMP_CODE_TABLE_NAME,
      FilterExpression: 'attribute_exists(redeemedByHouseholdId)',
      ProjectionExpression: 'code',
      ExclusiveStartKey: lastKey,
    }));
    redeemed += page.Count ?? 0;
    lastKey = page.LastEvaluatedKey;
  } while (lastKey);
  return redeemed <= FOUNDER_COMP_LIMIT;
}

/**
 * Codes get read aloud and typed by hand, so the alphabet already excludes O, 0,
 * I and 1. Casing, spaces and the dashes people add themselves are not part of
 * the code.
 */
export function normalize(raw: string): string {
  return (raw ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
}


function isConditionFailure(error: unknown): boolean {
  return (error as { name?: string })?.name === 'ConditionalCheckFailedException';
}
