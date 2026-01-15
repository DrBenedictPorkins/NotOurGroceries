import { DynamoDBClient, UpdateItemCommand, GetItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import type { Schema } from '../resource';

const client = new DynamoDBClient({});

const HOUSEHOLD_TABLE_NAME = process.env.HOUSEHOLD_TABLE_NAME!;
const USER_TABLE_NAME = process.env.USER_TABLE_NAME!;

type Handler = Schema['regenerateInviteCode']['functionHandler'];

/**
 * Generate a new 6-character invite code (alphanumeric, no ambiguous chars)
 */
function generateInviteCode(): string {
  const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let code = '';
  for (let i = 0; i < 6; i++) {
    code += letters.charAt(Math.floor(Math.random() * letters.length));
  }
  return code;
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
    const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
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
