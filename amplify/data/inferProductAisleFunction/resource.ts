import { defineFunction, secret } from '@aws-amplify/backend';

export const inferProductAisleFunction = defineFunction({
  name: 'inferProductAisleFunction',
  entry: './handler.ts',
  resourceGroupName: 'data',
  timeoutSeconds: 60,
  memoryMB: 512,
  environment: {
    ANTHROPIC_API_KEY: secret('ANTHROPIC_API_KEY'),
  },
});
