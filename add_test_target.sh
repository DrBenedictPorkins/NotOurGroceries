#!/bin/bash

# Script to help verify test setup for GroceryApp
# This script checks if test files are properly configured

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$PROJECT_DIR/GroceryAppTests"
PROJECT_FILE="$PROJECT_DIR/GroceryApp.xcodeproj"

echo "🔍 Checking GroceryApp Test Setup..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if test directory exists
if [ -d "$TEST_DIR" ]; then
    echo "✅ Test directory exists: $TEST_DIR"
else
    echo "❌ Test directory not found: $TEST_DIR"
    exit 1
fi

# Count test files
TEST_FILES=$(find "$TEST_DIR" -name "*Tests.swift" | wc -l | tr -d ' ')
echo "✅ Found $TEST_FILES test files"

# List test files
echo ""
echo "📄 Test Files:"
find "$TEST_DIR" -name "*Tests.swift" -exec basename {} \;

# Check if Info.plist exists
if [ -f "$TEST_DIR/Info.plist" ]; then
    echo "✅ Info.plist exists"
else
    echo "⚠️  Info.plist not found"
fi

# Check if README exists
if [ -f "$TEST_DIR/README.md" ]; then
    echo "✅ README.md exists"
else
    echo "⚠️  README.md not found"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Test Statistics:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Count test functions in each file
for file in "$TEST_DIR"/*Tests.swift; do
    if [ -f "$file" ]; then
        filename=$(basename "$file")
        test_count=$(grep -c "func test" "$file" || echo "0")
        echo "  $filename: $test_count tests"
    fi
done

TOTAL_TESTS=$(find "$TEST_DIR" -name "*Tests.swift" -exec grep -c "func test" {} + | awk '{s+=$1} END {print s}')
echo ""
echo "📈 Total test functions: $TOTAL_TESTS"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🎯 Next Steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Open GroceryApp.xcodeproj in Xcode"
echo "2. File → New → Target → Unit Testing Bundle"
echo "3. Name it 'GroceryAppTests'"
echo "4. Delete the auto-generated test file"
echo "5. Right-click GroceryAppTests → Add Files"
echo "6. Select all .swift files from GroceryAppTests directory"
echo "7. Press Cmd+U to run tests"
echo ""
echo "For detailed instructions, see: GroceryAppTests/README.md"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Try to list schemes
if command -v xcodebuild &> /dev/null; then
    echo ""
    echo "🔧 Available Xcode Schemes:"
    xcodebuild -list -project "$PROJECT_FILE" 2>/dev/null | grep -A 100 "Schemes:" || echo "  (Could not detect schemes)"
fi

echo ""
echo "✨ Setup verification complete!"
