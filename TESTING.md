# Jest Testing Setup for Lambda Functions

## Overview

This project now includes comprehensive Jest tests for all Lambda functions in the `/amplify/data` directory.

## Test Coverage

### Lambda Functions Tested

1. **addItemFunction** - Add grocery items to shopping lists
   - Name normalization
   - Duplicate detection
   - Atomic sequence number generation
   - User info lookup with email fallback
   - Main handler flow with error handling

2. **checkOffItemFunction** - Mark items as crossed off
   - Lock validation
   - Version management and optimistic locking
   - User authentication
   - Commit record creation
   - Concurrent modification handling

3. **restoreItemFunction** - Restore crossed off items
   - Status validation
   - Sequence number management
   - Version control
   - Data integrity preservation

4. **lockItemFunction** - Lock/unlock items
   - Lock/unlock logic
   - Action determination
   - Update expression handling
   - Version management

5. **searchProductsFunction** - Product search with fuzzy matching
   - Exact match search
   - Prefix match search
   - Fuzzy search with Levenshtein distance
   - Similarity scoring
   - Alias matching
   - Result sorting and limiting

6. **joinHouseholdFunction** - Join household with invite code
   - Invite code validation
   - Expiration checking
   - Duplicate membership prevention
   - User household updates

7. **regenerateInviteCodeFunction** - Generate new invite codes
   - 6-character alphanumeric code generation
   - Ambiguous character exclusion (O, I, 0, 1)
   - Member validation
   - 24-hour expiration setting

8. **sendInviteEmailFunction** - Send invite emails via SES
   - Email content generation (HTML and text)
   - Expiration validation
   - Member validation
   - SES integration
   - Error handling

## Running Tests

### Run all tests
```bash
npm test
```

### Run tests in watch mode
```bash
npm run test:watch
```

### Run tests with coverage
```bash
npm run test:coverage
```

### Run specific test file
```bash
npm test -- addItemFunction.handler.test.ts
```

## Test Structure

Each handler has its own test file located next to the handler:
```
amplify/data/
  ├── addItemFunction/
  │   ├── handler.ts
  │   └── handler.test.ts
  ├── checkOffItemFunction/
  │   ├── handler.ts
  │   └── handler.test.ts
  └── ...
```

## What Is Tested

### Key Business Logic
- **Duplicate detection** - Ensuring items aren't added twice
- **Name normalization** - Case-insensitive deduplication
- **Sequence number generation** - Atomic increments for commit ordering
- **User info lookup** - With fallback to email extraction
- **Optimistic locking** - Version-based concurrent modification detection
- **Lock validation** - Preventing unauthorized item modifications
- **Invite code generation** - Random 6-character codes without ambiguous characters
- **Expiration checking** - 24-hour invite code validity
- **Fuzzy search** - Levenshtein distance-based product matching
- **Error handling** - Proper error propagation and user-friendly messages

### NOT Tested
- Simple type checks and validations
- Trivial getters/setters
- AWS SDK directly (mocked instead)
- Configuration loading

## Mock Strategy

All tests use Jest mocks for:
- **DynamoDB Client** - All database operations
- **SES Client** - Email sending operations
- **marshall/unmarshall** - DynamoDB data marshalling utilities

Example mock setup:
```typescript
const mockSend = jest.fn();
(DynamoDBClient as jest.MockedClass<typeof DynamoDBClient>)
  .mockImplementation(() => ({ send: mockSend } as any));
```

## Test Patterns

### Testing Async Functions
```typescript
it('should add item successfully', async () => {
  mockSend.mockResolvedValueOnce({ Items: [] }); // Setup mock
  const result = await handler(mockEvent as any, mockContext as any);
  expect(result).toBeDefined();
});
```

### Testing Error Cases
```typescript
it('should throw error for duplicate item', async () => {
  mockSend.mockResolvedValueOnce({ Items: [existingItem] });
  await expect(handler(mockEvent as any, mockContext as any))
    .rejects.toThrow('DUPLICATE_ITEM');
});
```

### Testing Multiple Sequential Operations
```typescript
mockSend
  .mockResolvedValueOnce({ Items: [] })      // First call
  .mockResolvedValueOnce({ Item: user })     // Second call
  .mockResolvedValueOnce({ Attributes: {} }) // Third call
```

## Coverage Thresholds

Current coverage requirements (can be increased as tests improve):
- Branches: 70%
- Functions: 70%
- Lines: 70%
- Statements: 70%

## Common Test Scenarios

### 1. User Authentication
- Valid user with sub claim
- Valid user with claims object
- Missing user identity
- Fallback username extraction

### 2. DynamoDB Operations
- Successful operations
- Item not found
- Concurrent modification (ConditionalCheckFailedException)
- Connection errors

### 3. Business Logic
- Valid input
- Edge cases (empty strings, special characters)
- Invalid input
- State validation

### 4. Error Handling
- Specific error types (DUPLICATE_ITEM, ITEM_LOCKED)
- Generic errors with proper wrapping
- Logging verification

## Troubleshooting

### TypeScript Errors
The jest.config.js is configured to ignore certain TypeScript diagnostic codes that are expected due to the AWS Lambda type definitions not perfectly matching the Amplify-generated types.

### Mock Not Working
Ensure mocks are cleared before each test:
```typescript
beforeEach(() => {
  jest.clearAllMocks();
});
```

### Async Test Timeout
If tests timeout, increase the Jest timeout:
```typescript
jest.setTimeout(10000); // 10 seconds
```

## Future Improvements

1. **Increase Coverage** - Aim for 80%+ coverage across all metrics
2. **Integration Tests** - Test actual DynamoDB Local integration
3. **E2E Tests** - Test complete flows across multiple Lambdas
4. **Performance Tests** - Measure Lambda execution time
5. **Load Tests** - Test concurrent operations and locking

## Contributing

When adding new Lambda functions:
1. Create a corresponding `.test.ts` file
2. Follow the existing test patterns
3. Mock all AWS service clients
4. Test the main business logic, not trivial validations
5. Ensure tests pass before committing: `npm test`
