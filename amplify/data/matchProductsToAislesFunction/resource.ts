import { defineFunction, secret } from '@aws-amplify/backend';

export const matchProductsToAislesFunction = defineFunction({
  name: 'matchProductsToAislesFunction',
  entry: './handler.ts',
  resourceGroupName: 'data',
  timeoutSeconds: 120, // 2 minutes for matching
  memoryMB: 512, // Less memory needed - no images
  environment: {
    ANTHROPIC_API_KEY: secret('ANTHROPIC_API_KEY'),
  },
});
