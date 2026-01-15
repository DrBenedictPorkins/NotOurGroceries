import { defineAuth } from '@aws-amplify/backend';

/**
 * Define and configure your auth resource
 * @see https://docs.amplify.aws/gen2/build-a-backend/auth
 */
export const auth = defineAuth({
  loginWith: {
    email: true,
    // Social providers can be added later with proper credentials:
    // externalProviders: {
    //   google: {
    //     clientId: secret('GOOGLE_CLIENT_ID'),
    //     clientSecret: secret('GOOGLE_CLIENT_SECRET'),
    //   },
    //   signInWithApple: {
    //     clientId: secret('APPLE_CLIENT_ID'),
    //     teamId: secret('APPLE_TEAM_ID'),
    //     keyId: secret('APPLE_KEY_ID'),
    //     privateKey: secret('APPLE_PRIVATE_KEY'),
    //   },
    //   callbackUrls: ['http://localhost:3000/auth/callback', 'myapp://'],
    //   logoutUrls: ['http://localhost:3000/', 'myapp://'],
    // },
  },
});
