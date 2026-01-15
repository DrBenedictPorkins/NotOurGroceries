module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  roots: ['<rootDir>/amplify/data'],
  testMatch: ['**/*.test.ts'],
  collectCoverageFrom: [
    'amplify/data/**/*.ts',
    '!amplify/data/**/*.test.ts',
    '!amplify/data/**/resource.ts',
  ],
  coverageThreshold: {
    global: {
      branches: 70,
      functions: 70,
      lines: 70,
      statements: 70,
    },
  },
  moduleFileExtensions: ['ts', 'tsx', 'js', 'jsx', 'json', 'node'],
  clearMocks: true,
  resetMocks: true,
  restoreMocks: true,
  transform: {
    '^.+\\.ts$': ['ts-jest', {
      tsconfig: {
        esModuleInterop: true,
        allowSyntheticDefaultImports: true,
        strict: false,
        skipLibCheck: true,
        noImplicitAny: false,
      },
      diagnostics: {
        ignoreCodes: [2554, 2339, 2322, 151001],
      },
    }],
  },
};
