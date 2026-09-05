import { defineStorage } from '@aws-amplify/backend';

/**
 * Item photos. **The client has no access to this bucket.**
 *
 * It used to grant `get`, `write` and `delete` on the whole `item-images/*`
 * prefix to `allow.authenticated` — which is any signed-in account, and signup
 * is open, so any stranger. Anybody holding a key could read, overwrite or
 * delete another household's photo. Withholding `list` narrowed how keys were
 * discovered; it never made a key safe to hold.
 *
 * Every read, write and delete now goes through `itemImageFunction`, which
 * compares the household id in the key with the caller's Cognito groups and
 * hands back a short-lived presigned URL. The bytes still travel straight to S3;
 * only the permission is brokered.
 *
 * `defineStorage` cannot express this itself, which is why there is a Lambda:
 * it offers per-user paths (`entity('identity')`, which would stop members of a
 * household seeing each other's photos — the point of the feature) and static
 * group names, while household groups are created one per household at runtime.
 *
 * The empty access rule is deliberate. Granting nothing here is what makes the
 * broker the only door.
 */
export const storage = defineStorage({
  name: 'aisleImages',
  access: () => ({}),
});
