import { logEvent, logWarning, logFailure } from '../telemetry';
import { DynamoDBClient, GetItemCommand, UpdateItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import { requireHousehold } from '../requireHousehold';
import { loadAllowance, isEntitled, setEntitlement } from '../allowance';
import type { Schema } from '../resource';

const client = new DynamoDBClient({});

const COMP_CODE_TABLE_NAME = process.env.COMP_CODE_TABLE_NAME!;

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

  if (!code) {
    return { status: 'INVALID', message: "That doesn't look like a code. Check it and try again." };
  }

  // Refuse before burning anything. Somebody who is already comped — or who has
  // paid — spending a code would take a slot out of the hundred and get nothing
  // for it.
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

  // Burn first, comp second.
  //
  // A comp without a burnt code means a code that can be spent again; a burnt
  // code without a comp means one person to fix by hand. The second is strictly
  // better, so the write that can fail goes first.
  //
  // The condition is the whole mechanism: `attribute_not_exists` on a single
  // item is atomic, so two people racing the same code produce exactly one
  // winner without a lock, a counter or a transaction.
  try {
    await client.send(new UpdateItemCommand({
      TableName: COMP_CODE_TABLE_NAME,
      Key: marshall({ code }),
      UpdateExpression: 'SET redeemedByHouseholdId = :hid, redeemedAt = :now, updatedAt = :now',
      ConditionExpression: 'attribute_exists(code) AND attribute_not_exists(redeemedByHouseholdId)',
      ExpressionAttributeValues: marshall({ ':hid': householdId, ':now': new Date().toISOString() }),
    }));
  } catch (error) {
    if (isConditionFailure(error)) {
      // Either there is no such code or it is already spent, and the two need
      // different words. One extra read, only on the failure path.
      const existing = await readCode(code);
      if (!existing) {
        logWarning('comp.codeInvalid', { householdId });
        return { status: 'INVALID', message: "That code isn't one of ours. Check it and try again." };
      }
      logWarning('comp.codeSpent', { householdId });
      return {
        status: 'SPENT',
        message: "That code has already been used. Everything still works — you're on the free plan.",
      };
    }
    logFailure('comp.burnFailed', error, { householdId });
    throw error;
  }

  await setEntitlement(householdId, 'COMPED');
  logEvent('comp.redeemed', { householdId });

  return {
    status: 'COMPED',
    message: "Done — your household's limits are lifted for good.",
  };
};

/**
 * Codes get read aloud and typed by hand, so the alphabet already excludes O, 0,
 * I and 1. Casing, spaces and the dashes people add themselves are not part of
 * the code.
 */
export function normalize(raw: string): string {
  return (raw ?? '').toUpperCase().replace(/[^A-Z0-9]/g, '');
}

async function readCode(code: string): Promise<Record<string, any> | null> {
  const result = await client.send(new GetItemCommand({
    TableName: COMP_CODE_TABLE_NAME,
    Key: marshall({ code }),
  }));
  return result.Item ? unmarshall(result.Item) : null;
}

function isConditionFailure(error: unknown): boolean {
  return (error as { name?: string })?.name === 'ConditionalCheckFailedException';
}
