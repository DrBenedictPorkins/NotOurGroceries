import { defineFunction, secret } from '@aws-amplify/backend';

export const aisleExtractionJobHandler = defineFunction({
  name: 'aisleExtractionJobHandler',
  entry: './handler.ts',
  resourceGroupName: 'data',
  timeoutSeconds: 900, // 15 minutes max
  memoryMB: 1024,
  environment: {
    ANTHROPIC_API_KEY: secret('ANTHROPIC_API_KEY'),
  },
});
