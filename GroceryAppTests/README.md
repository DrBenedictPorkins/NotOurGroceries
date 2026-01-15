# GroceryApp Test Suite

This directory contains comprehensive unit tests for the GroceryApp iOS application using XCTest framework.

## Test Coverage

### 1. ShoppingListViewModelTests.swift
Tests the core business logic in `ShoppingListViewModel`:
- **JSON Parsing Tests** (parseGroceryItem, parseProduct)
  - Valid JSON parsing with all fields
  - Crossed-off and locked item parsing
  - Missing required fields handling
  - Optional null fields handling
  - Invalid date format handling
  - Mixed type filtering in arrays
- **Sorting Tests** (sortByDefault, sortByAisle)
  - Custom vs community item separation
  - Alphabetical sorting
  - Edge cases (empty lists)

**Total Test Cases**: 25+ tests

### 2. AuthErrorParsingTests.swift
Tests authentication error handling from `AuthGateView`:
- **Cognito Error Parsing** (parseCognitoError)
  - Username exists, user not found, invalid password
  - Code expired, code mismatch, user not confirmed
  - Limit exceeded, password reset, resource not found
- **Auth Error Parsing** (parseAuthError)
  - Configuration, service, validation errors
  - Not authorized, invalid state, session expired
  - Underlying Cognito error extraction
  - Generic error fallback

**Total Test Cases**: 20+ tests

### 3. GroceryItemTests.swift
Tests the `GroceryItem` model:
- **Initialization Tests**
  - Default values
  - All parameters
  - Auto-normalized name generation
- **ItemStatus Enum Tests**
  - Raw value encoding/decoding
  - Invalid raw values
- **Codable Tests**
  - JSON encoding/decoding
  - Date handling with ISO8601
- **Hashable Tests**
  - Set uniqueness by ID
  - Equality comparison
- **Mutable Property Tests**
  - Status, quantity, notes, version
  - Lock and crossed-off fields
- **Preview Helpers**

**Total Test Cases**: 30+ tests

### 4. ProductTests.swift
Tests the `Product` model:
- **Initialization Tests**
  - Default values
  - Custom normalized names
  - Aliases and store mappings
- **Codable Tests**
  - JSON encoding/decoding
  - Empty arrays and dictionaries
- **Hashable Tests**
  - Set uniqueness by ID
- **Edge Cases**
  - Special characters, Unicode
  - Very long alias lists and mappings
  - Preview helpers

**Total Test Cases**: 25+ tests

### 5. UserTests.swift
Tests the `User` model:
- **Initialization Tests**
  - Default values
  - Optional fields (avatarUrl, householdId)
- **Mutable Property Tests**
  - displayName, avatarUrl, householdId, lastActive
- **Codable Tests**
  - JSON encoding/decoding
  - Null optional fields
- **Hashable Tests**
  - Set uniqueness by ID
- **Edge Cases**
  - Long display names
  - Special characters and emojis
  - Date initialization

**Total Test Cases**: 20+ tests

## Total Coverage
**~120+ unit tests** covering all testable business logic, parsing functions, and model operations.

## What's NOT Tested (By Design)
- SwiftUI Views (requires UI testing)
- Direct Amplify API calls (should be mocked or tested via integration tests)
- Network layer (requires integration testing)
- Real-time subscriptions (requires integration testing)

## Adding Test Target to Xcode

Since the test files were created manually, you need to add them to your Xcode project:

### Option 1: Using Xcode GUI (Recommended)

1. Open `GroceryApp.xcodeproj` in Xcode
2. **Create Test Target:**
   - File → New → Target
   - Select "Unit Testing Bundle"
   - Product Name: "GroceryAppTests"
   - Language: Swift
   - Project: GroceryApp
   - Target to be Tested: GroceryApp
3. **Add Test Files:**
   - Delete the auto-generated test file
   - Right-click on GroceryAppTests folder in Project Navigator
   - Add Files to "GroceryApp"
   - Select all `.swift` files from `GroceryAppTests` directory
   - Make sure "GroceryAppTests" target is checked
4. **Configure Test Target:**
   - Select GroceryAppTests target
   - Build Settings → Search "host application"
   - Set "Host Application" to GroceryApp.app
5. **Add Dependencies:**
   - Select GroceryAppTests target
   - Build Phases → Link Binary With Libraries
   - Add: XCTest.framework
   - Add: Amplify (if needed)
   - Add: AWSCognitoAuthPlugin (if needed)

### Option 2: Using Command Line

If you prefer to add the test target via project.pbxproj editing, you can:

1. Open the project in Xcode
2. File → New → Target → Unit Testing Bundle
3. Drag the test files from Finder into the test target

### Option 3: Using xcodebuild

```bash
# From the project directory
xcodebuild -list  # Check available schemes

# Run tests once target is added
xcodebuild test -scheme GroceryApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Running Tests

### In Xcode
1. Open project in Xcode
2. Press `Cmd + U` to run all tests
3. Or click the diamond icon next to individual test functions
4. View results in Test Navigator (`Cmd + 6`)

### From Command Line
```bash
# Run all tests
xcodebuild test -scheme GroceryApp -destination 'platform=iOS Simulator,name=iPhone 15'

# Run specific test class
xcodebuild test -scheme GroceryApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:GroceryAppTests/ShoppingListViewModelTests

# Run specific test
xcodebuild test -scheme GroceryApp -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:GroceryAppTests/ShoppingListViewModelTests/testParseGroceryItem_WithValidJSON_ReturnsItem
```

## Test Organization

Tests follow the naming convention:
```
test[MethodName]_[Condition]_[ExpectedResult]
```

Examples:
- `testParseGroceryItem_WithValidJSON_ReturnsItem`
- `testSortByDefault_SeparatesCustomAndCommunityItems`
- `testParseCognitoError_UserNotFound_ReturnsCorrectMessage`

## Code Changes Made for Testability

To enable testing, the following methods were changed from `private` to `internal` (default access):

**In ShoppingListViewModel.swift:**
- `parseGroceryItem(_ json: JSONValue) -> GroceryItem?`
- `parseProduct(_ json: JSONValue) -> Product?`
- `sortByAisle()`
- `sortByDefault()`

These methods are now testable without breaking encapsulation significantly, as they remain internal to the module.

## Continuous Integration

To integrate with CI/CD:

### GitHub Actions Example
```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v2
      - name: Run tests
        run: xcodebuild test -scheme GroceryApp -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Test Coverage Report
```bash
# Generate coverage report
xcodebuild test -scheme GroceryApp -destination 'platform=iOS Simulator,name=iPhone 15' -enableCodeCoverage YES

# View coverage in Xcode
# Open Report Navigator (Cmd + 9) → Coverage tab
```

## Future Enhancements

Consider adding:
1. **Integration Tests**: Test Amplify API interactions with mocked backend
2. **UI Tests**: Test SwiftUI views and user interactions
3. **Performance Tests**: Use `measure` blocks for performance-critical code
4. **Snapshot Tests**: Verify UI appearance consistency
5. **Mock Services**: Create mock AmplifyService for isolated testing

## Troubleshooting

### "Cannot find 'GroceryApp' in scope"
- Ensure GroceryApp is set as the test host application
- Check that test target has access to app module (`@testable import GroceryApp`)

### "Module 'Amplify' not found"
- Add Amplify framework to test target's Linked Frameworks

### Tests not appearing in Test Navigator
- Clean build folder (Cmd + Shift + K)
- Rebuild test target (Cmd + B)
- Restart Xcode

### "Private method not accessible"
- Check that methods are marked `internal` (default) or `public`, not `private`
- Ensure `@testable import GroceryApp` is used

## Best Practices

1. **Arrange-Act-Assert**: All tests follow AAA pattern
2. **Isolated Tests**: Each test is independent
3. **Descriptive Names**: Test names clearly describe what's being tested
4. **Edge Cases**: Tests cover happy path, error cases, and edge cases
5. **No External Dependencies**: Tests use pure Swift/Foundation types
6. **Fast Execution**: Tests run in milliseconds without network calls

## Maintenance

When adding new features:
1. Write tests for new parsing functions
2. Write tests for new business logic
3. Write tests for new model properties
4. Update this README with new test coverage
5. Aim for >80% code coverage on testable logic
