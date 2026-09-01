import { defineStorage } from '@aws-amplify/backend';

/**
 * Item photos.
 *
 * `authenticated` here means *any* signed-in account, not any member of the
 * household that owns the file. Signup is open, so that is any stranger. This is
 * the S3 equivalent of the state the data models were in before per-household
 * authorization, and it is not fixed yet.
 *
 * `list` is withheld, which is the part that makes it survivable in the
 * meantime. With it, one new account could enumerate every key in the bucket and
 * delete every household's photos. Without it, reaching a file means guessing
 * `item-images/{householdId}_{itemId}_{imageId}.jpg` — three UUIDs — which is
 * not a realistic attack. Nothing reads by listing.
 *
 * That narrows the blast radius; it does not scope access. Anyone holding a key
 * can still read, overwrite or delete a file belonging to someone else.
 *
 * **The real fix, before any public release:** deny direct client access and
 * broker every read and write through a Lambda that checks the caller's Cognito
 * group against the household id in the key. `defineStorage` cannot express this
 * itself — it offers per-user paths (`entity('identity')`, which would stop
 * household members sharing a photo at all) and static group names, and
 * household groups are created dynamically, one per household.
 *
 * Two alternatives were considered and rejected. Per-user paths break sharing,
 * which is the point of the feature. Scoping the authenticated role with an IAM
 * principal tag would need `custom:householdId` mirrored onto the Cognito user
 * and kept in sync with the DynamoDB row — a third copy of the same fact, and
 * mirroring that fact is what broke the members list and the join path already.
 */
export const storage = defineStorage({
  name: 'aisleImages',
  access: (allow) => ({
    'item-images/*': [
      allow.authenticated.to(['get', 'write', 'delete']),
    ],
  }),
});
