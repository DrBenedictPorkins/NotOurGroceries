import {
  DynamoDBClient,
  GetItemCommand,
  UpdateItemCommand,
  QueryCommand,
  DeleteItemCommand,
  BatchWriteItemCommand,
  PutItemCommand,
} from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import {
  CognitoIdentityProviderClient,
  AdminAddUserToGroupCommand,
  AdminRemoveUserFromGroupCommand,
  CreateGroupCommand,
  DeleteGroupCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import { randomInt, randomUUID } from 'node:crypto';
import type { Schema } from '../resource';

const client = new DynamoDBClient({});
const cognito = new CognitoIdentityProviderClient({});

const USER_POOL_ID = process.env.USER_POOL_ID!;

/**
 * Membership is enforced by AppSync through a Cognito group named after the
 * household, so detaching somebody means removing that claim as well as
 * clearing the column. Leave the group behind and they keep read access to
 * every row until their token expires — the row still says householdId X and
 * their token still says they are in group X.
 *
 * Best effort: a failure here is logged, not thrown. The DynamoDB change is
 * what the app reads, and a stale group without a matching householdId grants
 * nothing on its own.
 */
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

/**
 * Six characters from a 32-letter alphabet with I, O, 0 and 1 left out, because
 * these get read aloud and typed by hand.
 *
 * `randomInt` rather than `Math.random()` — the old regenerate path used
 * `Math.random()`, which is predictable, for a string whose only job is to keep
 * strangers out of somebody's household.
 */
/**
 * An invite code lives 30 minutes and admits one person.
 *
 * Short because the code is now handed over deliberately — you generate it with
 * the person in front of you, or you text it and they act on it. A code that
 * outlives that conversation is just a spare key left in a group chat.
 */
const INVITE_CODE_TTL_MS = 30 * 60 * 1000;

const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

async function generateUniqueInviteCode(): Promise<string> {
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = Array.from({ length: 6 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join('');

    // 32^6 is about a billion, so a collision is unlikely — but nothing checked
    // before, and a duplicate silently sends joiners to whichever row DynamoDB
    // returns first.
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

async function addToHouseholdGroup(userId: string, householdId: string): Promise<void> {
  try {
    await cognito.send(new CreateGroupCommand({
      UserPoolId: USER_POOL_ID,
      GroupName: householdId,
      Description: `Members of household ${householdId}`,
    }));
  } catch (error) {
    if ((error as { name?: string }).name !== 'GroupExistsException') throw error;
  }

  await cognito.send(new AdminAddUserToGroupCommand({
    UserPoolId: USER_POOL_ID,
    Username: userId,
    GroupName: householdId,
  }));
}

async function deleteHouseholdGroup(householdId: string): Promise<void> {
  try {
    await cognito.send(new DeleteGroupCommand({
      UserPoolId: USER_POOL_ID,
      GroupName: householdId,
    }));
  } catch (error) {
    console.error(`Could not delete group ${householdId}:`, error);
  }
}

const HOUSEHOLD_TABLE_NAME = process.env.HOUSEHOLD_TABLE_NAME!;
const USER_TABLE_NAME = process.env.USER_TABLE_NAME!;
const GROCERY_ITEM_TABLE_NAME = process.env.GROCERY_ITEM_TABLE_NAME!;
const COMMIT_TABLE_NAME = process.env.COMMIT_TABLE_NAME!;
const HOUSEHOLD_STORE_TABLE_NAME = process.env.HOUSEHOLD_STORE_TABLE_NAME!;

type Handler = Schema['manageHouseholdMembership']['functionHandler'];

/**
 * Membership changes that a member cannot make from the client.
 *
 * `User` is `allow.owner()`, so nobody can clear anybody else's `householdId`
 * through the API — removal is not merely unimplemented in the app, it is
 * impossible without a function that holds its own table permissions. That is
 * this. It is also where the owner check has to live: an owner check written in
 * SwiftUI is decoration while `Household` is `allow.authenticated()`.
 *
 * Three actions:
 *   create — make a household and put the caller in it as owner
 *   remove — the owner removes somebody else
 *   leave  — anybody removes themselves, owner included
 *
 * Creation is here rather than a plain `createHousehold` model mutation because
 * three things about a new household must not be client-supplied: the owner (it
 * is whoever is calling, not whoever the payload names), the invite code (six
 * characters that let anyone in — generated with a CSPRNG and checked for
 * collision), and the Cognito group without which the creator cannot read a
 * single row of what they just made.
 *
 * Leaving empties a household when the last member goes, and an empty household
 * is deleted along with its items, history and stores. Households are cheap to
 * recreate; one left standing with nobody in it and a live invite code is not
 * something anybody will come back to clean up.
 */

interface HouseholdRow {
  id: string;
  name: string;
  ownerId?: string;
}

async function getHousehold(householdId: string): Promise<HouseholdRow | null> {
  const result = await client.send(new GetItemCommand({
    TableName: HOUSEHOLD_TABLE_NAME,
    Key: marshall({ id: householdId }),
  }));
  if (!result.Item) return null;
  const row = unmarshall(result.Item);
  return { id: row.id, name: row.name, ownerId: row.ownerId };
}

async function getUserHouseholdId(userId: string): Promise<string | null> {
  const result = await client.send(new GetItemCommand({
    TableName: USER_TABLE_NAME,
    Key: marshall({ id: userId }),
  }));
  if (!result.Item) return null;
  return unmarshall(result.Item).householdId || null;
}

/**
 * Detach a user from their household.
 *
 * REMOVE, not set-to-empty. The old client wrote `""`, which is not null: it is
 * an empty string in the hash key of the User GSI, which DynamoDB rejects as an
 * index key, and which the app then read back as a non-nil household id and
 * routed the user into a household that does not exist.
 */
async function detachUser(userId: string): Promise<void> {
  await client.send(new UpdateItemCommand({
    TableName: USER_TABLE_NAME,
    Key: marshall({ id: userId }),
    // householdGroup goes with it — it is what the read rule matches on.
    UpdateExpression: 'REMOVE householdId, householdGroup SET updatedAt = :now',
    ExpressionAttributeValues: marshall({ ':now': new Date().toISOString() }),
  }));
}

async function countMembers(householdId: string): Promise<number> {
  const result = await client.send(new QueryCommand({
    TableName: USER_TABLE_NAME,
    IndexName: 'usersByHouseholdId',
    KeyConditionExpression: 'householdId = :hid',
    ExpressionAttributeValues: marshall({ ':hid': householdId }),
    Select: 'COUNT',
  }));
  return result.Count ?? 0;
}

/**
 * Delete everything belonging to a household, then the household itself.
 *
 * Paginated and batched, because a household with a long history has thousands
 * of Commit rows and a single Query returns at most 1MB. Failures are logged and
 * skipped rather than thrown: a half-deleted household with no members is untidy,
 * but a member left attached to a household the caller believes is gone is worse.
 */
async function deleteHouseholdData(householdId: string): Promise<void> {
  const scoped: { table: string; index: string }[] = [
    { table: GROCERY_ITEM_TABLE_NAME, index: 'groceryItemsByHouseholdIdAndStatus' },
    { table: COMMIT_TABLE_NAME, index: 'commitsByHouseholdIdAndSequenceNumber' },
    { table: HOUSEHOLD_STORE_TABLE_NAME, index: 'householdStoresByHouseholdId' },
  ];

  for (const { table, index } of scoped) {
    let lastKey: Record<string, unknown> | undefined;
    do {
      try {
        const page = await client.send(new QueryCommand({
          TableName: table,
          IndexName: index,
          KeyConditionExpression: 'householdId = :hid',
          ExpressionAttributeValues: marshall({ ':hid': householdId }),
          ProjectionExpression: 'id',
          ExclusiveStartKey: lastKey as never,
        }));

        const ids = (page.Items ?? []).map((item) => unmarshall(item).id as string);
        for (let i = 0; i < ids.length; i += 25) {
          await client.send(new BatchWriteItemCommand({
            RequestItems: {
              [table]: ids.slice(i, i + 25).map((id) => ({
                DeleteRequest: { Key: marshall({ id }) },
              })),
            },
          }));
        }

        lastKey = page.LastEvaluatedKey as Record<string, unknown> | undefined;
      } catch (error) {
        console.error(`Could not clear ${table} for household ${householdId}:`, error);
        lastKey = undefined;
      }
    } while (lastKey);
  }

  // ProductAisleMapping and AisleExtractionJob hang off storeId rather than
  // householdId, so they are not reachable by this query and are left behind.
  // They are inert without the store that owns them.
  await client.send(new DeleteItemCommand({
    TableName: HOUSEHOLD_TABLE_NAME,
    Key: marshall({ id: householdId }),
  }));
}

export const handler: Handler = async (event) => {
  const { action, memberId, name } = event.arguments;

  const identity = (event as typeof event & {
    identity?: { sub?: string; claims?: Record<string, unknown> };
  }).identity;
  const callerId = identity?.sub || (identity?.claims?.['sub'] as string);

  if (!callerId) {
    throw new Error('User identity not found');
  }

  if (action === 'create') {
    const householdName = (name ?? '').trim();
    if (!householdName) {
      throw new Error('A household needs a name');
    }

    const existing = await getUserHouseholdId(callerId);
    if (existing) {
      throw new Error('You are already in a household. Leave it first.');
    }

    const newId = randomUUID();
    const inviteCode = await generateUniqueInviteCode();
    const now = new Date();
    const expires = new Date(now.getTime() + INVITE_CODE_TTL_MS);

    // Group first. A household the creator cannot read is worse than no
    // household — and if this throws, nothing has been written yet.
    await addToHouseholdGroup(callerId, newId);

    await client.send(new PutItemCommand({
      TableName: HOUSEHOLD_TABLE_NAME,
      Item: marshall({
        id: newId,
        name: householdName,
        // The field the auth rule reads. Same value as the id — see the comment
        // on the model for why it cannot just be the id.
        groupName: newId,
        // Taken from the caller's identity, never from the payload.
        ownerId: callerId,
        inviteCode,
        inviteCodeExpiresAt: expires.toISOString(),
        sequenceNumber: 0,
        createdAt: now.toISOString(),
        updatedAt: now.toISOString(),
        __typename: 'Household',
      }),
    }));

    await client.send(new UpdateItemCommand({
      TableName: USER_TABLE_NAME,
      Key: marshall({ id: callerId }),
      // householdGroup mirrors householdId; the read rule matches on it because
      // householdId is a GSI key and cannot carry an auth filter.
      // The creator is the household's first member, so they get the first
      // colour. Everyone after them is assigned one the household is not using.
      UpdateExpression: 'SET householdId = :hid, householdGroup = :hid, profileColor = if_not_exists(profileColor, :colour), updatedAt = :now',
      ExpressionAttributeValues: marshall({ ':hid': newId, ':colour': 'cyan', ':now': now.toISOString() }),
    }));

    console.log(`User ${callerId} created household ${newId}`);
    return {
      householdId: newId,
      householdDeleted: false,
      remainingMembers: 1,
      inviteCode,
    };
  }

  const householdId = await getUserHouseholdId(callerId);
  if (!householdId) {
    throw new Error('You are not in a household');
  }

  const household = await getHousehold(householdId);
  if (!household) {
    throw new Error('Household not found');
  }

  if (action === 'remove') {
    if (!memberId) {
      throw new Error('No member specified');
    }
    // Only the owner removes people, and never themselves — leaving is its own
    // action with its own consequences.
    if (household.ownerId !== callerId) {
      throw new Error('Only the person who created this household can remove members');
    }
    if (memberId === callerId) {
      throw new Error('Use leave to remove yourself');
    }
    if (await getUserHouseholdId(memberId) !== householdId) {
      throw new Error('That person is not in this household');
    }

    await detachUser(memberId);
    await removeFromHouseholdGroup(memberId, householdId);
    console.log(`Owner ${callerId} removed ${memberId} from household ${householdId}`);

    return { householdId, householdDeleted: false, remainingMembers: await countMembers(householdId) };
  }

  if (action === 'leave') {
    await detachUser(callerId);
    await removeFromHouseholdGroup(callerId, householdId);

    const remaining = await countMembers(householdId);
    if (remaining === 0) {
      await deleteHouseholdData(householdId);
      await deleteHouseholdGroup(householdId);
      console.log(`Household ${householdId} emptied and deleted`);
      return { householdId, householdDeleted: true, remainingMembers: 0 };
    }

    // The owner is allowed to walk out. What is left is a household nobody can
    // be removed from, which is fine — the remaining members can leave too, and
    // one of them can make a new one. Promoting somebody automatically would be
    // the app deciding whose household it is.
    console.log(`User ${callerId} left household ${householdId}, ${remaining} remaining`);
    return { householdId, householdDeleted: false, remainingMembers: remaining };
  }

  throw new Error(`Unknown action: ${action}`);
};
