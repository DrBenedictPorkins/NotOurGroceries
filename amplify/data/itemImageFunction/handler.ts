import type { AppSyncResolverHandler } from 'aws-lambda';
import { S3Client, GetObjectCommand, PutObjectCommand, DeleteObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { randomUUID } from 'node:crypto';
import { requireHousehold } from '../requireHousehold';
import { logEvent, logWarning, logFailure } from '../telemetry';
import type { Schema } from '../resource';

const s3 = new S3Client({});
const BUCKET = process.env.IMAGE_BUCKET_NAME!;

/**
 * How long a signed link lives.
 *
 * Long enough to load a photo on a bad connection in a shop, short enough that a
 * link pasted somewhere by accident stops working the same afternoon. Uploads
 * get less because the app uses them immediately.
 */
const READ_TTL_SECONDS = 15 * 60;
const WRITE_TTL_SECONDS = 5 * 60;

const PREFIX = 'item-images/';

/**
 * Which household owns this key?
 *
 * Keys are `item-images/{householdId}_{itemId}_{imageId}.jpg`. The household id
 * is a UUID, which contains hyphens but never an underscore, so the first
 * underscore ends it. Returns null for anything that is not shaped like one of
 * our keys — including `..`, a leading slash, or a different prefix.
 */
function householdFromKey(key: string): string | null {
  if (!key.startsWith(PREFIX)) return null;
  if (key.includes('..') || key.includes('//')) return null;

  const rest = key.slice(PREFIX.length);
  const underscore = rest.indexOf('_');
  if (underscore <= 0) return null;

  const householdId = rest.slice(0, underscore);
  return /^[0-9a-fA-F-]{36}$/.test(householdId) ? householdId : null;
}

type Handler = Schema['itemImage']['functionHandler'];

/**
 * Broker every read, write and delete of an item photo.
 *
 * The bucket used to grant `get`, `write` and `delete` on the whole
 * `item-images/*` prefix to `allow.authenticated` — which is any signed-in
 * account, and signup is open, so any stranger. Anybody holding a key could read
 * or delete somebody else's photo. `list` was withheld as a stopgap, which made
 * keys hard to discover without making them safe to hold.
 *
 * `defineStorage` cannot express this itself: it offers per-user paths, which
 * would stop members of a household sharing a photo at all, and static group
 * names, while household groups are created one per household at runtime. So
 * the client gets no S3 permissions and comes here instead, and this compares
 * the household id in the key against the caller's own Cognito groups.
 *
 * Reads and writes come back as presigned URLs so the bytes still go straight to
 * S3 and never through Lambda. Deletes are done here rather than signed, because
 * a signed DELETE is a capability worth nothing to the client and everything to
 * whoever else ends up holding it.
 */
export const handler: AppSyncResolverHandler<
  { action: string; s3Key?: string | null; itemId?: string | null; householdId?: string | null },
  unknown
> = async (event) => {
  const callerHouseholds = requireHousehold(event);
  const { action, s3Key, itemId, householdId } = event.arguments;

  if (action === 'upload') {
    if (!itemId || !householdId) throw new Error('itemId and householdId are required to upload');
    if (!callerHouseholds.includes(householdId)) {
      logWarning('auth.rejected', { reason: 'upload_outside_household' });
      throw new Error('You can only add photos to your own household.');
    }

    // Built here, not accepted from the client. A caller that chooses its own
    // key chooses where the file lands, and the ownership check above is only
    // worth as much as the key it is checking.
    const key = `${PREFIX}${householdId}_${itemId}_${randomUUID()}.jpg`;
    const url = await getSignedUrl(
      s3,
      new PutObjectCommand({ Bucket: BUCKET, Key: key, ContentType: 'image/jpeg' }),
      { expiresIn: WRITE_TTL_SECONDS }
    );

    logEvent('image.uploadSigned', { householdId, ttl: WRITE_TTL_SECONDS });
    return { url, s3Key: key, expiresIn: WRITE_TTL_SECONDS };
  }

  if (!s3Key) throw new Error('s3Key is required');

  const owner = householdFromKey(s3Key);
  if (!owner) {
    logWarning('auth.rejected', { reason: 'malformed_image_key' });
    throw new Error('That is not a valid image.');
  }
  if (!callerHouseholds.includes(owner)) {
    logWarning('auth.rejected', { reason: 'image_outside_household' });
    throw new Error('That photo belongs to another household.');
  }

  if (action === 'read') {
    const url = await getSignedUrl(
      s3,
      new GetObjectCommand({ Bucket: BUCKET, Key: s3Key }),
      { expiresIn: READ_TTL_SECONDS }
    );
    logEvent('image.readSigned', { householdId: owner, ttl: READ_TTL_SECONDS });
    return { url, s3Key, expiresIn: READ_TTL_SECONDS };
  }

  if (action === 'delete') {
    try {
      await s3.send(new DeleteObjectCommand({ Bucket: BUCKET, Key: s3Key }));
    } catch (error) {
      logFailure('image.deleteFailed', error, { householdId: owner });
      throw new Error('Could not delete that photo. Try again.');
    }
    logEvent('image.deleted', { householdId: owner });
    return { url: null, s3Key, expiresIn: 0 };
  }

  throw new Error(`Unknown action: ${action}`);
};
