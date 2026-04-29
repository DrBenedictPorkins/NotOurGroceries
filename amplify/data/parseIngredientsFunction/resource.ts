import { defineFunction, secret } from '@aws-amplify/backend';

export const parseIngredientsFunction = defineFunction({
  name: 'parseIngredientsFunction',
  entry: './handler.ts',
  resourceGroupName: 'data',
  timeoutSeconds: 30,
  memoryMB: 256,
  environment: {
    ANTHROPIC_API_KEY: secret('ANTHROPIC_API_KEY'),
  },
});
