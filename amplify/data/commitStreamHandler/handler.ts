import { DynamoDBStreamHandler } from 'aws-lambda';
import { DynamoDBClient, UpdateItemCommand, PutItemCommand, GetItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';

const client = new DynamoDBClient({});

const HOUSEHOLD_TABLE_NAME = process.env.HOUSEHOLD_TABLE_NAME!;
const COMMIT_TABLE_NAME = process.env.COMMIT_TABLE_NAME!;
const USER_TABLE_NAME = process.env.USER_TABLE_NAME!;

/**
 * Get next sequence number atomically from Household table.
 *
 * Returns null when the household no longer exists, which means the record that
 * triggered this is part of a household being deleted and no commit should be
 * written for it.
 *
 * The condition is load-bearing. `UpdateItem` **creates the item if it is
 * absent**, so without it deleting a household resurrected it: the cascade
 * removed the household row, its own item deletions came back through this
 * stream, and each one recreated the household as a stub carrying nothing but
 * an id and a sequence number — alongside one orphaned Commit per deleted item.
 * Observed 2026-09-04 on the last-member-deletes-account path: 18 items removed,
 * 18 REMOVE_ITEM commits written, and a household that reported itself deleted
 * still sitting in the table.
 */
async function getNextSequenceNumber(householdId: string): Promise<number | null> {
  try {
    const result = await client.send(new UpdateItemCommand({
      TableName: HOUSEHOLD_TABLE_NAME,
      Key: marshall({ id: householdId }),
      UpdateExpression: 'SET sequenceNumber = if_not_exists(sequenceNumber, :zero) + :inc',
      ConditionExpression: 'attribute_exists(id)',
      ExpressionAttributeValues: marshall({
        ':inc': 1,
        ':zero': 0,
      }),
      ReturnValues: 'UPDATED_NEW',
    }));

    const attrs = result.Attributes ? unmarshall(result.Attributes) : {};
    return attrs.sequenceNumber as number;
  } catch (error) {
    if ((error as { name?: string }).name === 'ConditionalCheckFailedException') {
      return null;
    }
    throw error;
  }
}

/**
 * Get user information from the User table
 */
async function getUserInfo(userId: string): Promise<{ displayName: string; avatarUrl?: string }> {
  const result = await client.send(new GetItemCommand({
    TableName: USER_TABLE_NAME,
    Key: marshall({ id: userId }),
  }));

  if (!result.Item) {
    console.warn(`User not found in database: ${userId}, using fallback`);
    return {
      displayName: 'Unknown User',
    };
  }

  const user = unmarshall(result.Item);

  return {
    displayName: user.displayName || 'Unknown User',
    avatarUrl: user.avatarUrl,
  };
}

/**
 * Determine the action type based on old and new images
 */
function determineAction(oldImage: any, newImage: any): string {
  // INSERT: New item added
  if (!oldImage && newImage) {
    return 'ADD_ITEM';
  }

  // REMOVE: Item deleted
  if (oldImage && !newImage) {
    return 'REMOVE_ITEM';
  }

  // MODIFY: Check what changed
  if (oldImage && newImage) {
    // Status changed from ACTIVE to CROSSED_OFF
    if (oldImage.status === 'ACTIVE' && newImage.status === 'CROSSED_OFF') {
      return 'CHECK_OFF_ITEM';
    }

    // Status changed from CROSSED_OFF to ACTIVE
    if (oldImage.status === 'CROSSED_OFF' && newImage.status === 'ACTIVE') {
      return 'RESTORE_ITEM';
    }

    // Lock status changed
    if (!oldImage.lockedBy && newImage.lockedBy) {
      return 'LOCK_ITEM';
    }

    if (oldImage.lockedBy && !newImage.lockedBy) {
      return 'UNLOCK_ITEM';
    }

    // Other modifications
    return 'UPDATE_ITEM';
  }

  return 'UNKNOWN';
}

/**
 * Create payload based on action type
 */
function createPayload(action: string, oldImage: any, newImage: any): any {
  const image = newImage || oldImage;

  switch (action) {
    case 'ADD_ITEM':
      return {
        itemId: image.id,
        name: image.name,
        quantity: image.quantity,
        notes: image.notes,
        isCustom: image.isCustom,
        productId: image.productId,
      };

    case 'REMOVE_ITEM':
      return {
        itemId: image.id,
        itemName: image.name,
        deletedAt: new Date().toISOString(),
      };

    case 'CHECK_OFF_ITEM':
      return {
        itemId: image.id,
        itemName: image.name,
        previousStatus: oldImage.status,
        newStatus: newImage.status,
        crossedOffAt: newImage.crossedOffAt,
      };

    case 'RESTORE_ITEM':
      return {
        itemId: image.id,
        itemName: image.name,
        previousStatus: oldImage.status,
        newStatus: newImage.status,
        restoredBy: newImage.addedBy,
        restoredAt: new Date().toISOString(),
      };

    case 'LOCK_ITEM':
    case 'UNLOCK_ITEM':
      return {
        itemId: image.id,
        itemName: image.name,
        lockedBy: newImage.lockedBy,
        version: newImage.version,
      };

    case 'UPDATE_ITEM':
    default:
      return {
        itemId: image.id,
        itemName: image.name,
        changes: {
          old: oldImage,
          new: newImage,
        },
      };
  }
}

/**
 * DynamoDB Stream handler for GroceryItem table
 * Creates Commit records for all item changes
 */
export const handler: DynamoDBStreamHandler = async (event) => {
  console.log('Stream handler invoked with', event.Records.length, 'records');

  for (const record of event.Records) {
    try {
      // Only process INSERT, MODIFY, and REMOVE events
      if (!record.dynamodb || !record.eventName) {
        continue;
      }

      const oldImage = record.dynamodb.OldImage ? unmarshall(record.dynamodb.OldImage as any) : null;
      const newImage = record.dynamodb.NewImage ? unmarshall(record.dynamodb.NewImage as any) : null;

      // Determine the action type
      const action = determineAction(oldImage, newImage);

      if (action === 'UNKNOWN') {
        console.warn('Unknown action type, skipping record');
        continue;
      }

      // Get household ID from either old or new image
      const householdId = (newImage || oldImage)?.householdId;
      if (!householdId) {
        console.warn('No householdId found in record, skipping');
        continue;
      }

      // Get the user who made the change (from new image for inserts/updates, old for deletes)
      const userId = (newImage || oldImage)?.addedBy;
      if (!userId) {
        console.warn('No userId found in record, skipping');
        continue;
      }

      // Get user information
      const userInfo = await getUserInfo(userId);

      // Get next sequence number. Null means the household is gone — this
      // record is the wake of a cascade, not activity worth recording.
      const sequenceNumber = await getNextSequenceNumber(householdId);
      if (sequenceNumber === null) {
        console.warn(JSON.stringify({
          event: 'commit.skipped',
          reason: 'household_deleted',
          householdId,
          action,
        }));
        continue;
      }

      // Create payload
      const payload = createPayload(action, oldImage, newImage);

      // Create commit record
      const now = new Date().toISOString();
      const commitId = `${householdId}-${sequenceNumber}`;

      await client.send(new PutItemCommand({
        TableName: COMMIT_TABLE_NAME,
        Item: marshall({
          id: commitId,
          householdId,
          sequenceNumber,
          author: userId,
          authorName: userInfo.displayName,
          action,
          payload,
          createdAt: now,
          updatedAt: now,
        }, { removeUndefinedValues: true }),
      }));

      console.log(`Created commit ${commitId} for action ${action}`);
    } catch (error) {
      console.error('Error processing stream record:', error);
      // Continue processing other records even if one fails
    }
  }
};
