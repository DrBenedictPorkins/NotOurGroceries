import {
  DynamoDBClient,
  GetItemCommand,
  UpdateItemCommand,
  QueryCommand,
  DeleteItemCommand,
  BatchWriteItemCommand,
} from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import type { Schema } from '../resource';

const client = new DynamoDBClient({});

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
 * Two actions:
 *   remove — the owner removes somebody else
 *   leave  — anybody removes themselves, owner included
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
    UpdateExpression: 'REMOVE householdId SET updatedAt = :now',
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
  const { action, memberId } = event.arguments;

  const identity = (event as typeof event & {
    identity?: { sub?: string; claims?: Record<string, unknown> };
  }).identity;
  const callerId = identity?.sub || (identity?.claims?.['sub'] as string);

  if (!callerId) {
    throw new Error('User identity not found');
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
    console.log(`Owner ${callerId} removed ${memberId} from household ${householdId}`);

    return { householdId, householdDeleted: false, remainingMembers: await countMembers(householdId) };
  }

  if (action === 'leave') {
    await detachUser(callerId);

    const remaining = await countMembers(householdId);
    if (remaining === 0) {
      await deleteHouseholdData(householdId);
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
