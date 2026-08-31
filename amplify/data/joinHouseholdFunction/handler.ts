import { DynamoDBClient, QueryCommand, UpdateItemCommand, GetItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import {
  CognitoIdentityProviderClient,
  CreateGroupCommand,
  AdminAddUserToGroupCommand,
  AdminRemoveUserFromGroupCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import type { Schema } from '../resource';

const client = new DynamoDBClient({});
const cognito = new CognitoIdentityProviderClient({});

const USER_POOL_ID = process.env.USER_POOL_ID!;

/**
 * Put the joiner in the household's Cognito group.
 *
 * AppSync authorizes every household-scoped row with
 * `allow.groupDefinedIn('householdId')`, which compares the row's householdId
 * against the caller's `cognito:groups` claim. Updating the User row alone would
 * move somebody into a household they cannot read a single record of.
 *
 * This one DOES throw. A join that silently grants no access is worse than a
 * join that fails and can be retried.
 *
 * The claim only appears in a freshly issued token, so the client must refresh
 * its session afterwards — see AmplifyService.joinHouseholdWithCode.
 */
async function addToHouseholdGroup(userId: string, householdId: string): Promise<void> {
  // Idempotent — the group usually exists already, and re-creating it is fine.
  try {
    await cognito.send(new CreateGroupCommand({
      UserPoolId: USER_POOL_ID,
      GroupName: householdId,
      Description: `Members of household ${householdId}`,
    }));
  } catch (error) {
    const name = (error as { name?: string }).name;
    if (name !== 'GroupExistsException') {
      console.error(`Could not create group ${householdId}:`, error);
    }
  }

  await cognito.send(new AdminAddUserToGroupCommand({
    UserPoolId: USER_POOL_ID,
    Username: userId,
    GroupName: householdId,
  }));
}

/** Drop the claim for a household they are leaving behind. */
async function removeFromHouseholdGroup(userId: string, householdId: string): Promise<void> {
  try {
    await cognito.send(new AdminRemoveUserFromGroupCommand({
      UserPoolId: USER_POOL_ID,
      Username: userId,
      GroupName: householdId,
    }));
  } catch (error) {
    console.error(`Could not remove ${userId} from group ${householdId}:`, error);
  }
}

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
/**
 * The six profile colours, in the order they are handed out.
 *
 * Mirrors `ProfileColor` in UserIdentityGradient.swift. The colour is the only
 * thing distinguishing one member's name from another's on a list row, so two
 * people in the same household must never be given the same one — which is why
 * this is assigned server-side, against the members who already exist, rather
 * than hashed from the user id (a 2-person household would collide 1 time in 6).
 */
const PROFILE_COLOURS = ['cyan', 'purple', 'pink', 'blue', 'yellow', 'green'];

async function colourForNewMember(householdId: string): Promise<string> {
  const taken = new Set<string>();
  let cursor: Record<string, unknown> | undefined;

  do {
    const page = await client.send(new QueryCommand({
      TableName: USER_TABLE_NAME,
      IndexName: 'usersByHouseholdId',
      KeyConditionExpression: 'householdId = :hid',
      ExpressionAttributeValues: marshall({ ':hid': householdId }),
      ProjectionExpression: 'profileColor',
      ExclusiveStartKey: cursor as never,
    }));
    for (const item of page.Items ?? []) {
      const colour = unmarshall(item).profileColor;
      if (colour) taken.add(colour);
    }
    cursor = page.LastEvaluatedKey as never;
  } while (cursor);

  // Past six members the palette repeats; there is nothing better to do, and a
  // household that large has bigger problems telling people apart.
  return PROFILE_COLOURS.find((c) => !taken.has(c)) ?? PROFILE_COLOURS[taken.size % PROFILE_COLOURS.length];
}

async function updateUserHousehold(userId: string, householdId: string, colour: string): Promise<void> {
  const now = new Date().toISOString();

  await client.send(new UpdateItemCommand({
    TableName: USER_TABLE_NAME,
    Key: marshall({ id: userId }),
    // householdGroup mirrors householdId — see the User model for why the auth
    // rule cannot read the key column directly.
    UpdateExpression: 'SET householdId = :householdId, householdGroup = :householdId, profileColor = if_not_exists(profileColor, :colour), updatedAt = :now',
    ExpressionAttributeValues: marshall({
      ':householdId': householdId,
      ':colour': colour,
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

    // Grant the claim first. If this fails the join throws and nothing has
    // changed, which is recoverable; the reverse order would leave somebody
    // pointed at a household they cannot read.
    await addToHouseholdGroup(userId, household.id);

    await updateUserHousehold(userId, household.id, await colourForNewMember(household.id));

    if (previousHouseholdId) {
      await removeFromHouseholdGroup(userId, previousHouseholdId);
    }

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
