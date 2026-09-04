import { DynamoDBClient, QueryCommand, UpdateItemCommand, GetItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import {
  CognitoIdentityProviderClient,
  CreateGroupCommand,
  AdminAddUserToGroupCommand,
  AdminRemoveUserFromGroupCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import { randomInt } from 'node:crypto';
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
const PROFILE_COLOURS = [
  'cyan', 'purple', 'pink', 'blue', 'yellow', 'green',
  'coral', 'sky', 'lavender', 'gold', 'rose', 'periwinkle',
];

/**
 * Same alphabet as the membership function: no I, O, 0 or 1, because these get
 * read aloud and typed by hand. `randomInt` rather than `Math.random()`.
 */
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

async function generateUniqueInviteCode(): Promise<string> {
  for (let attempt = 0; attempt < 5; attempt++) {
    // Eight, not six. A code is read aloud and typed by hand, so length is
    // friction — but 32^6 is 1.07e9 and 32^8 is 1.1e12, a thousandfold, for two
    // more characters and about a second of typing. Still shorter than a guest
    // Wi-Fi password.
    const code = Array.from({ length: 8 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');
    const existing = await client.send(new QueryCommand({
      TableName: HOUSEHOLD_TABLE_NAME,
      IndexName: 'householdsByInviteCode',
      KeyConditionExpression: 'inviteCode = :code',
      ExpressionAttributeValues: marshall({ ':code': code }),
      Select: 'COUNT',
    }));
    if (!existing.Count) return code;
    console.warn(`Invite code collision on ${code}, retrying`);
  }
  throw new Error('Could not generate a unique invite code');
}

/**
 * Spend the invite code, so it admits exactly one person.
 *
 * The condition is what makes it single-use: two people racing the same code
 * both read the same row, but only the first conditional write matches, and the
 * loser is told to ask for a new one rather than silently joining.
 *
 * The code is rotated *and* expired. Rotating means the string that was texted
 * around can never work again, whatever the expiry logic does later; expiring
 * means the fresh string is not a live invite nobody asked for — a member has to
 * press Generate New Code deliberately.
 *
 * Spent before the joiner is granted anything. If a later step fails they are
 * left outside holding a dead code, which a member fixes by regenerating; the
 * other order would let two people through on one code, which nothing fixes.
 */
async function consumeInviteCode(householdId: string, usedCode: string): Promise<void> {
  const replacement = await generateUniqueInviteCode();
  try {
    await client.send(new UpdateItemCommand({
      TableName: HOUSEHOLD_TABLE_NAME,
      Key: marshall({ id: householdId }),
      UpdateExpression: 'SET inviteCode = :new, inviteCodeExpiresAt = :spent, updatedAt = :now',
      ConditionExpression: 'inviteCode = :used',
      ExpressionAttributeValues: marshall({
        ':new': replacement,
        ':used': usedCode,
        // Already in the past, so the replacement is not itself a live invite.
        ':spent': new Date().toISOString(),
        ':now': new Date().toISOString(),
      }),
    }));
  } catch (error: unknown) {
    if ((error as { name?: string }).name === 'ConditionalCheckFailedException') {
      throw new Error('This invite code has already been used. Please request a new one from a household member.');
    }
    throw error;
  }
}

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

  // Random among whatever is left, not the first free one. Handing them out in
  // palette order made the first member of every household cyan and the second
  // purple, which looks like a default rather than an identity.
  const free = PROFILE_COLOURS.filter((c) => !taken.has(c));
  if (free.length > 0) return free[randomInt(free.length)];

  // Past six members the palette has to repeat; there is nothing better to do,
  // and a household that large has bigger problems telling people apart.
  return PROFILE_COLOURS[randomInt(PROFILE_COLOURS.length)];
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

    // Single use. Spent before anything is granted — see consumeInviteCode.
    await consumeInviteCode(household.id, inviteCode);

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
