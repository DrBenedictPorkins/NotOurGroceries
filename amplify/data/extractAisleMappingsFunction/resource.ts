import { defineFunction, secret } from '@aws-amplify/backend';

export const extractAisleMappingsFunction = defineFunction({
  name: 'extractAisleMappingsFunction',
  entry: './handler.ts',
  resourceGroupName: 'data',
  timeoutSeconds: 120, // 2 minutes - Claude Vision with large images needs time
  memoryMB: 512, // More memory helps Lambda run faster
  environment: {
    ANTHROPIC_API_KEY: secret('ANTHROPIC_API_KEY'),
  },
});
