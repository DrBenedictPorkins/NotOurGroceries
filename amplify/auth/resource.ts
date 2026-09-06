import { defineAuth, defineFunction, secret } from '@aws-amplify/backend';

/**
 * Puts an invite code in the sign-up confirmation email.
 *
 * A verified address is the gate: a code minted at the moment Cognito sends the
 * confirmation is one that cannot be scraped, because the scarce thing was never
 * the code — it is an account somebody proved they can receive mail at.
 */
export const customMessageFunction = defineFunction({
  name: 'customMessageFunction',
  entry: './customMessageFunction/handler.ts',
  // The only thing it needs. Resolved from SSM at runtime, so it creates no
  // CloudFormation dependency on another stack — which is the entire reason this
  // function derives codes instead of reading a table.
  environment: {
    COMP_CODE_SECRET: secret('COMP_CODE_SECRET'),
  },
});

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
  triggers: {
    customMessage: customMessageFunction,
  },
  // Password policy is not expressible here; it is set on the underlying
  // Cognito construct in `backend.ts`.
});
