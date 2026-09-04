import { randomInt } from 'node:crypto';
import { DynamoDBClient, UpdateItemCommand, GetItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import type { Schema } from '../resource';
import { requireHousehold } from '../requireHousehold';

/**
 * An invite code lives 10 minutes and admits one person.
 *
 * Short because the code is now handed over deliberately — you generate it with
 * the person in front of you, or you text it and they act on it. A code that
 * outlives that conversation is just a spare key left in a group chat.
 */
// Ten minutes. An invite is sent while both people are looking at their
// phones — in the same room, or on a text that gets answered now. Half an hour
// was a guess, and nobody waits half an hour to join a shopping list. Any
// member can press Generate New Code, so the cost of expiring early is one tap,
// while the cost of a long window is a live code sitting in a message thread.
const INVITE_CODE_TTL_MS = 10 * 60 * 1000;

const client = new DynamoDBClient({});

const HOUSEHOLD_TABLE_NAME = process.env.HOUSEHOLD_TABLE_NAME!;
const USER_TABLE_NAME = process.env.USER_TABLE_NAME!;

type Handler = Schema['regenerateInviteCode']['functionHandler'];

/**
 * Generate a new invite code.
 *
 * `randomInt` from node:crypto, not `Math.random()`. This function used
 * `Math.random()` — a PRNG seeded per process and not built to be
 * unpredictable — for the one string standing between a stranger and somebody's
 * household. Observing a handful of codes from the same warm Lambda narrows the
 * next one considerably. The other two generators were fixed; this one was
 * missed, and it is the path "Generate New Code" in the app actually calls.
 *
 * Eight characters from a 32-symbol alphabet with the ambiguous ones removed —
 * no O/0, no I/1 — because this gets read aloud.
 */
function generateInviteCode(): string {
  const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  return Array.from({ length: 8 }, () => letters[randomInt(letters.length)]).join('');
}

/**
 * Check if user is a member of the household
 */
async function isUserMember(userId: string, householdId: string): Promise<boolean> {
  try {
    const result = await client.send(new GetItemCommand({
      TableName: USER_TABLE_NAME,
      Key: marshall({ id: userId }),
    }));

    if (result.Item) {
      const user = unmarshall(result.Item);
      return user.householdId === householdId;
    }
  } catch (error) {
    console.error('Error checking user membership:', error);
  }
  return false;
}

export const handler: Handler = async (event) => {
  requireHousehold(event);
  console.log('regenerateInviteCode Lambda invoked');
  console.log('Event:', JSON.stringify(event, null, 2));

  try {
    const { householdId } = event.arguments;

    // Get user identity
    const eventWithIdentity = event as typeof event & {
      identity?: {
        sub?: string;
        claims?: Record<string, unknown>;
      }
    };

    const identity = eventWithIdentity.identity;
    const userId = identity?.sub || (identity?.claims?.['sub'] as string);

    if (!userId) {
      throw new Error('User identity not found');
    }

    // Verify user is a member of this household
    const isMember = await isUserMember(userId, householdId);
    if (!isMember) {
      throw new Error('You are not a member of this household');
    }

    // Generate new invite code with 24-hour expiration
    const newInviteCode = generateInviteCode();
    const expiresAt = new Date(Date.now() + INVITE_CODE_TTL_MS).toISOString();
    const now = new Date().toISOString();

    // Update household with new invite code
    await client.send(new UpdateItemCommand({
      TableName: HOUSEHOLD_TABLE_NAME,
      Key: marshall({ id: householdId }),
      UpdateExpression: 'SET inviteCode = :inviteCode, inviteCodeExpiresAt = :expiresAt, updatedAt = :now',
      ExpressionAttributeValues: marshall({
        ':inviteCode': newInviteCode,
        ':expiresAt': expiresAt,
        ':now': now,
      }),
    }));

    console.log('Invite code regenerated successfully for household:', householdId);

    return {
      inviteCode: newInviteCode,
      expiresAt: expiresAt,
    };
  } catch (error) {
    console.error('Error regenerating invite code:', error);
    throw error;
  }
};
