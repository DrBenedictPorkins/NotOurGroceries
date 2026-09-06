import { logEvent, logWarning, logFailure } from '../telemetry';
import {
  DynamoDBClient,
  GetItemCommand,
  UpdateItemCommand,
  PutItemCommand,
} from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import { requireHousehold } from '../requireHousehold';
import type { Schema } from '../resource';

const client = new DynamoDBClient({});

const GROCERY_ITEM_TABLE_NAME = process.env.GROCERY_ITEM_TABLE_NAME!;
const HOUSEHOLD_TABLE_NAME = process.env.HOUSEHOLD_TABLE_NAME!;

type Handler = Schema['finishShopping']['functionHandler'];

/**
 * Ending a shopping trip, in one call.
 *
 * It used to be roughly forty-one: one mutation per item moved to suggestions,
 * one per trip-scoped note cleared, and finally one on the household to put the
 * trip away. That was slow online and broken offline, and broken in the worst
 * shape — the item mutations ran first and queued happily, then the household
 * mutation threw, so the items had moved but the trip had not ended. No
 * completion sheet, nothing recorded, and the shopper left stranded on the At
 * Store screen with a trip the rest of the household could still see running.
 *
 * So the client now decides the whole outcome locally — it already has to, to
 * show the completion sheet — and sends it here as one statement of the final
 * state. One call to retry when the signal comes back instead of forty-one, and
 * no way to end up half finished.
 *
 * This is deliberately not a merge. It does not ask what the server thinks the
 * list looks like or try to reconcile. The shopper was standing in the shop;
 * their phone is right about what is in the trolley.
 */
export const handler: Handler = async (event) => {
  const households = requireHousehold(event);
  const {
    tripId,
    householdId,
    toSuggestion,
    clearNotesFor,
    created,
    endTrip,
  } = event.arguments;

  // The token says which households this caller belongs to. Anything else is
  // somebody addressing another household's rows by id.
  if (!households.includes(householdId)) {
    logWarning('shopping.finishRejected', { reason: 'not_a_member', householdId });
    throw new Error('You are not a member of that household.');
  }

  const itemIds = (toSuggestion ?? []).filter((id): id is string => !!id);
  const noteIds = (clearNotesFor ?? []).filter((id): id is string => !!id);
  const newItems = parseCreated(created);
  const now = new Date().toISOString();

  // Idempotency. This call is the one thing in the finish path that can be
  // queued and retried, so it will sometimes arrive twice — a reply lost on a
  // bad connection looks exactly like a failure to the phone that sent it.
  // Applying it twice would drag a list somebody has since rebuilt back into
  // suggestions, which is precisely the sort of silent data loss this app has
  // already been bitten by once.
  const household = await readHousehold(householdId);
  if (!household) {
    logWarning('shopping.finishRejected', { reason: 'no_household', householdId });
    throw new Error('That household no longer exists.');
  }
  if (household.lastFinishedTripId === tripId) {
    logEvent('shopping.finishAlreadyApplied', { householdId, tripId });
    return {
      tripId,
      alreadyApplied: true,
      itemsUpdated: 0,
      itemsCreated: 0,
      notesCleared: 0,
      householdEnded: false,
    };
  }

  let itemsCreated = 0;
  let itemsUpdated = 0;
  let notesCleared = 0;

  // Items added during the trip while offline. The server has never seen these,
  // so there is nothing to update — they arrive whole, with the status the
  // client already decided, and are written as they are.
  for (const item of newItems) {
    if (item.householdId !== householdId) {
      logWarning('shopping.finishSkippedItem', { reason: 'wrong_household', householdId });
      continue;
    }
    try {
      await client.send(new PutItemCommand({
        TableName: GROCERY_ITEM_TABLE_NAME,
        Item: marshall({
          ...item,
          createdAt: item.createdAt ?? now,
          updatedAt: now,
          __typename: 'GroceryItem',
        }, { removeUndefinedValues: true }),
        // Never clobber a row that already exists. If the create reached the
        // server on an earlier attempt, the update pass below owns it.
        ConditionExpression: 'attribute_not_exists(id)',
      }));
      itemsCreated += 1;
    } catch (error) {
      if (isConditionFailure(error)) continue;
      logFailure('shopping.finishCreateFailed', error, { householdId, itemId: item.id });
      throw error;
    }
  }

  for (const id of itemIds) {
    if (await setStatusToSuggestion(id, householdId, now)) itemsUpdated += 1;
  }

  for (const id of noteIds) {
    if (await clearTripNote(id, householdId, now)) notesCleared += 1;
  }

  // Last, so that a failure part way through leaves the trip open rather than
  // closed over a list that was not finished being put away. Closing it is the
  // cheap half; a retry re-runs the rest harmlessly because every write above
  // is idempotent on its own.
  let householdEnded = false;
  if (endTrip) {
    await client.send(new UpdateItemCommand({
      TableName: HOUSEHOLD_TABLE_NAME,
      Key: marshall({ id: householdId }),
      UpdateExpression:
        'SET shoppingStatus = :idle, lastFinishedTripId = :trip, updatedAt = :now ' +
        'REMOVE activeShopperId, shoppingStoreId, shoppingStartedAt',
      ExpressionAttributeValues: marshall({
        ':idle': 'IDLE',
        ':trip': tripId,
        ':now': now,
      }),
    }));
    householdEnded = true;
  } else {
    // No trip to close — it was never announced, because it started with no
    // signal. Still record the id so a retry of this same call is recognised.
    await client.send(new UpdateItemCommand({
      TableName: HOUSEHOLD_TABLE_NAME,
      Key: marshall({ id: householdId }),
      UpdateExpression: 'SET lastFinishedTripId = :trip, updatedAt = :now',
      ExpressionAttributeValues: marshall({ ':trip': tripId, ':now': now }),
    }));
  }

  logEvent('shopping.finished', {
    householdId,
    tripId,
    itemsUpdated,
    itemsCreated,
    notesCleared,
    householdEnded,
  });

  return { tripId, alreadyApplied: false, itemsUpdated, itemsCreated, notesCleared, householdEnded };
};

// MARK: - Writes

/**
 * Every item write carries the household as a condition.
 *
 * The item table is keyed by id alone, so without this a caller could name any
 * row in the database and move it. The token check above proves membership of
 * the household in the argument; this proves the row belongs to it.
 *
 * `version` is bumped so clients treating it as a change counter notice, and
 * `updatedAt` moves so the stream that writes history has something to write.
 */
async function setStatusToSuggestion(id: string, householdId: string, now: string): Promise<boolean> {
  try {
    await client.send(new UpdateItemCommand({
      TableName: GROCERY_ITEM_TABLE_NAME,
      Key: marshall({ id }),
      UpdateExpression: 'SET #status = :s, updatedAt = :now ADD #version :one',
      ConditionExpression: 'attribute_exists(id) AND householdId = :hid',
      ExpressionAttributeNames: { '#status': 'status', '#version': 'version' },
      ExpressionAttributeValues: marshall({
        ':s': 'SUGGESTION',
        ':now': now,
        ':one': 1,
        ':hid': householdId,
      }),
    }));
    return true;
  } catch (error) {
    // A row deleted mid-trip is not an error worth failing the whole finish
    // over — the item is gone, which is where it was heading anyway.
    if (isConditionFailure(error)) return false;
    logFailure('shopping.finishUpdateFailed', error, { householdId, itemId: id });
    throw error;
  }
}

/** Trip-scoped notes ("get only 1", "optional if found") die with the trip. */
async function clearTripNote(id: string, householdId: string, now: string): Promise<boolean> {
  try {
    await client.send(new UpdateItemCommand({
      TableName: GROCERY_ITEM_TABLE_NAME,
      Key: marshall({ id }),
      UpdateExpression:
        'SET notesEphemeral = :false, updatedAt = :now REMOVE notes ADD #version :one',
      ConditionExpression: 'attribute_exists(id) AND householdId = :hid',
      ExpressionAttributeNames: { '#version': 'version' },
      ExpressionAttributeValues: marshall({
        ':false': false,
        ':now': now,
        ':one': 1,
        ':hid': householdId,
      }),
    }));
    return true;
  } catch (error) {
    if (isConditionFailure(error)) return false;
    logFailure('shopping.finishNoteClearFailed', error, { householdId, itemId: id });
    throw error;
  }
}

// MARK: - Reads and parsing

async function readHousehold(householdId: string): Promise<Record<string, any> | null> {
  const result = await client.send(new GetItemCommand({
    TableName: HOUSEHOLD_TABLE_NAME,
    Key: marshall({ id: householdId }),
  }));
  return result.Item ? unmarshall(result.Item) : null;
}

/**
 * `created` arrives as JSON because its shape is a GroceryItem, and repeating
 * fourteen fields in the GraphQL argument list would mean editing this mutation
 * every time the model gains one.
 *
 * Anything that is not an array of objects with an id is dropped rather than
 * throwing: a malformed extra item must not cost somebody the rest of their
 * finished trip.
 */
function parseCreated(created: unknown): Record<string, any>[] {
  if (!created) return [];
  let value: unknown = created;
  if (typeof value === 'string') {
    try {
      value = JSON.parse(value);
    } catch {
      logWarning('shopping.finishCreatedUnparsable', {});
      return [];
    }
  }
  if (!Array.isArray(value)) return [];
  return value.filter(
    (item): item is Record<string, any> =>
      !!item && typeof item === 'object' && typeof (item as any).id === 'string',
  );
}

function isConditionFailure(error: unknown): boolean {
  return (error as { name?: string })?.name === 'ConditionalCheckFailedException';
}
