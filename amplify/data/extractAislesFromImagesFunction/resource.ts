import { defineFunction, secret } from '@aws-amplify/backend';

export const extractAislesFromImagesFunction = defineFunction({
  name: 'extractAislesFromImagesFunction',
  entry: './handler.ts',
  resourceGroupName: 'data',
  timeoutSeconds: 120, // 2 minutes for OCR
  memoryMB: 1024,
  environment: {
    ANTHROPIC_API_KEY: secret('ANTHROPIC_API_KEY'),
  },
});
