import { defineFunction, secret } from '@aws-amplify/backend';

export const transcribeAudioFunction = defineFunction({
  name: 'transcribeAudioFunction',
  entry: './handler.ts',
  resourceGroupName: 'data',
  timeoutSeconds: 60,
  memoryMB: 256,
  environment: {
    OPENAI_API_KEY: secret('OPENAI_API_KEY'),
  },
});
