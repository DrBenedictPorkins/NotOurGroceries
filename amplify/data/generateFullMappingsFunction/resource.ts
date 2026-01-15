import { defineFunction, secret } from '@aws-amplify/backend';

export const generateFullMappingsFunction = defineFunction({
  name: 'generateFullMappingsFunction',
  entry: './handler.ts',
  resourceGroupName: 'data',
  timeoutSeconds: 300, // 5 minutes - processing many products takes time
  memoryMB: 512, // More memory for handling large product lists
  environment: {
    ANTHROPIC_API_KEY: secret('ANTHROPIC_API_KEY'),
  },
});
