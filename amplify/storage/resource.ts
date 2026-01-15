import { defineStorage } from '@aws-amplify/backend';

export const storage = defineStorage({
  name: 'aisleImages',
  access: (allow) => ({
    // Allow any authenticated user to upload/read/delete store images
    // Images are organized by storeId, and any household member can manage them
    'store-images/*': [
      allow.authenticated.to(['read', 'write', 'delete']),
    ],
    'item-images/*': [
      allow.authenticated.to(['read', 'write', 'delete']),
    ],
  }),
});
