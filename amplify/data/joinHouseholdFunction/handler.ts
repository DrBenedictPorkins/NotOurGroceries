import { DynamoDBClient, QueryCommand, UpdateItemCommand, GetItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import type { Schema } from '../resource';

const client = new DynamoDBClient({});

const HOUSEHOLD_TABLE_NAME = process.env.HOUSEHOLD_TABLE_NAME!;
const USER_TABLE_NAME = process.env.USER_TABLE_NAME!;

type Handler = Schema['joinHousehold']['functionHandler'];

/**
 * Find a household by invite code
 */
async function findHouseholdByInviteCode(inviteCode: string): Promise<{ id: string; name: string; inviteCodeExpiresAt: string } | null> {
  const result = await client.send(new QueryCommand({
    TableName: HOUSEHOLD_TABLE_NAME,
    IndexName: 'householdsByInviteCode',
    KeyConditionExpression: 'inviteCode = :inviteCode',
    ExpressionAttributeValues: marshall({
      ':inviteCode': inviteCode.toUpperCase(),
    }),
  }));

  if (result.Items && result.Items.length > 0) {
    const household = unmarshall(result.Items[0]);
    return {
      id: household.id,
      name: household.name,
      inviteCodeExpiresAt: household.inviteCodeExpiresAt,
    };
  }

  return null;
}

/**
 * Get user's current household ID
 */
async function getUserHouseholdId(userId: string): Promise<string | null> {
  const result = await client.send(new GetItemCommand({
    TableName: USER_TABLE_NAME,
    Key: marshall({ id: userId }),
  }));

  if (result.Item) {
    const user = unmarshall(result.Item);
    return user.householdId || null;
  }

  return null;
}

/**
 * Update user's household ID
 */
async function updateUserHousehold(userId: string, householdId: string): Promise<void> {
  const now = new Date().toISOString();

  await client.send(new UpdateItemCommand({
    TableName: USER_TABLE_NAME,
    Key: marshall({ id: userId }),
    UpdateExpression: 'SET householdId = :householdId, updatedAt = :now',
    ExpressionAttributeValues: marshall({
      ':householdId': householdId,
      ':now': now,
    }),
  }));
}

export const handler: Handler = async (event) => {
  console.log('joinHousehold Lambda invoked');
  console.log('Event:', JSON.stringify(event, null, 2));

  try {
    const { inviteCode } = event.arguments;

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

    // Find household by invite code
    const household = await findHouseholdByInviteCode(inviteCode);
    if (!household) {
      throw new Error('Invalid invite code');
    }

    // Check if invite code is expired
    const expiresAt = new Date(household.inviteCodeExpiresAt);
    if (expiresAt < new Date()) {
      throw new Error('This invite code has expired. Please request a new one from a household member.');
    }

    // Get user's current household (if any)
    const previousHouseholdId = await getUserHouseholdId(userId);

    // Check if user is already in this household
    if (previousHouseholdId === household.id) {
      throw new Error('You are already a member of this household');
    }

    // Update user's household
    await updateUserHousehold(userId, household.id);

    console.log(`User ${userId} joined household ${household.id}`);

    return {
      householdId: household.id,
      householdName: household.name,
      previousHouseholdId: previousHouseholdId || undefined,
    };
  } catch (error) {
    console.error('Error joining household:', error);
    throw error;
  }
};
