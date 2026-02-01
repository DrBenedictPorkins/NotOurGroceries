#!/bin/bash
#
# Release script for NotOurGroceries iOS app
# Automates version bumping, changelog updates, and git tagging
#
# Usage:
#   ./scripts/release.sh [options]
#
# Options:
#   --bump-build   (default) Only increment build number
#   --bump-minor   Increment minor version (1.0 -> 1.1) and reset build to 1
#   --bump-major   Increment major version (1.0 -> 2.0) and reset build to 1
#   --bump-patch   Increment patch version (1.0.0 -> 1.0.1) and reset build to 1
#   --dry-run      Show what would happen without making changes

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory and project paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PBXPROJ_PATH="$PROJECT_ROOT/GroceryApp.xcodeproj/project.pbxproj"
CHANGELOG_PATH="$PROJECT_ROOT/CHANGELOG.md"

# Default options
BUMP_TYPE="build"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bump-build)
            BUMP_TYPE="build"
            shift
            ;;
        --bump-minor)
            BUMP_TYPE="minor"
            shift
            ;;
        --bump-major)
            BUMP_TYPE="major"
            shift
            ;;
        --bump-patch)
            BUMP_TYPE="patch"
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --bump-build   (default) Only increment build number"
            echo "  --bump-minor   Increment minor version (1.0 -> 1.1) and reset build to 1"
            echo "  --bump-major   Increment major version (1.0 -> 2.0) and reset build to 1"
            echo "  --bump-patch   Increment patch version (1.0.0 -> 1.0.1) and reset build to 1"
            echo "  --dry-run      Show what would happen without making changes"
            echo "  -h, --help     Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Verify we're in the right directory
if [[ ! -f "$PBXPROJ_PATH" ]]; then
    echo -e "${RED}Error: project.pbxproj not found at $PBXPROJ_PATH${NC}"
    echo "Please run this script from the NotOurGroceries project root."
    exit 1
fi

# Check for uncommitted changes (warning only)
if ! git -C "$PROJECT_ROOT" diff --quiet HEAD 2>/dev/null; then
    echo -e "${YELLOW}Warning: You have uncommitted changes in your working directory.${NC}"
    if [[ "$DRY_RUN" == false ]]; then
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
    fi
fi

# Extract current version and build from project.pbxproj
# Look for MARKETING_VERSION in the target build settings (not project-level)
CURRENT_VERSION=$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ_PATH" | sed 's/.*MARKETING_VERSION = //' | sed 's/;.*//' | tr -d ' "')
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ_PATH" | sed 's/.*CURRENT_PROJECT_VERSION = //' | sed 's/;.*//' | tr -d ' "')

if [[ -z "$CURRENT_VERSION" ]]; then
    echo -e "${RED}Error: Could not find MARKETING_VERSION in project.pbxproj${NC}"
    exit 1
fi

if [[ -z "$CURRENT_BUILD" ]]; then
    echo -e "${RED}Error: Could not find CURRENT_PROJECT_VERSION in project.pbxproj${NC}"
    exit 1
fi

echo -e "${BLUE}Current version: $CURRENT_VERSION (build $CURRENT_BUILD)${NC}"

# Parse version components
# Handle both X.Y and X.Y.Z formats
IFS='.' read -ra VERSION_PARTS <<< "$CURRENT_VERSION"
MAJOR=${VERSION_PARTS[0]:-0}
MINOR=${VERSION_PARTS[1]:-0}
PATCH=${VERSION_PARTS[2]:-0}

# Calculate new version based on bump type
case $BUMP_TYPE in
    build)
        NEW_VERSION="$CURRENT_VERSION"
        NEW_BUILD=$((CURRENT_BUILD + 1))
        ;;
    minor)
        MINOR=$((MINOR + 1))
        PATCH=0
        NEW_VERSION="$MAJOR.$MINOR.$PATCH"
        NEW_BUILD=1
        ;;
    major)
        MAJOR=$((MAJOR + 1))
        MINOR=0
        PATCH=0
        NEW_VERSION="$MAJOR.$MINOR.$PATCH"
        NEW_BUILD=1
        ;;
    patch)
        PATCH=$((PATCH + 1))
        NEW_VERSION="$MAJOR.$MINOR.$PATCH"
        NEW_BUILD=1
        ;;
esac

echo -e "${GREEN}New version: $NEW_VERSION (build $NEW_BUILD)${NC}"
echo ""

# Dry run output
if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}=== DRY RUN MODE ===${NC}"
    echo ""
    echo "Would update:"
    echo "  - MARKETING_VERSION: $CURRENT_VERSION -> $NEW_VERSION"
    echo "  - CURRENT_PROJECT_VERSION: $CURRENT_BUILD -> $NEW_BUILD"
    echo ""
    echo "Would update CHANGELOG.md:"
    echo "  - Move [Unreleased] items to [$NEW_VERSION] - $(date +%Y-%m-%d)"
    echo ""
    echo "Would create git commit:"
    echo "  - Message: Release v$NEW_VERSION (build $NEW_BUILD)"
    echo ""
    echo "Would create git tag:"
    echo "  - Tag: v$NEW_VERSION-$NEW_BUILD"
    echo "  - Message: Release v$NEW_VERSION (build $NEW_BUILD)"
    echo ""
    exit 0
fi

# Update project.pbxproj
echo "Updating project.pbxproj..."

# Use sed to update all occurrences of MARKETING_VERSION and CURRENT_PROJECT_VERSION
# macOS sed requires slightly different syntax
if [[ "$(uname)" == "Darwin" ]]; then
    # macOS
    sed -i '' "s/MARKETING_VERSION = $CURRENT_VERSION;/MARKETING_VERSION = $NEW_VERSION;/g" "$PBXPROJ_PATH"
    sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ_PATH"
else
    # Linux
    sed -i "s/MARKETING_VERSION = $CURRENT_VERSION;/MARKETING_VERSION = $NEW_VERSION;/g" "$PBXPROJ_PATH"
    sed -i "s/CURRENT_PROJECT_VERSION = $CURRENT_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PBXPROJ_PATH"
fi

# Verify the update was successful
VERIFY_VERSION=$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ_PATH" | sed 's/.*MARKETING_VERSION = //' | sed 's/;.*//' | tr -d ' "')
VERIFY_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PBXPROJ_PATH" | sed 's/.*CURRENT_PROJECT_VERSION = //' | sed 's/;.*//' | tr -d ' "')

if [[ "$VERIFY_VERSION" != "$NEW_VERSION" ]] || [[ "$VERIFY_BUILD" != "$NEW_BUILD" ]]; then
    echo -e "${RED}Error: Failed to update project.pbxproj${NC}"
    echo "Expected: $NEW_VERSION (build $NEW_BUILD)"
    echo "Got: $VERIFY_VERSION (build $VERIFY_BUILD)"
    exit 1
fi

echo -e "  ${GREEN}Updated MARKETING_VERSION to $NEW_VERSION${NC}"
echo -e "  ${GREEN}Updated CURRENT_PROJECT_VERSION to $NEW_BUILD${NC}"

# Update CHANGELOG.md
echo ""
echo "Updating CHANGELOG.md..."

if [[ -f "$CHANGELOG_PATH" ]]; then
    TODAY=$(date +%Y-%m-%d)

    # Check if there's content under [Unreleased]
    UNRELEASED_CONTENT=$(awk '/^## \[Unreleased\]/{found=1; next} /^## \[/{found=0} found' "$CHANGELOG_PATH" | grep -v '^$' || true)

    if [[ -n "$UNRELEASED_CONTENT" ]]; then
        # There's content to move - insert new version section after [Unreleased]
        if [[ "$(uname)" == "Darwin" ]]; then
            # macOS: Add new version section after [Unreleased] line
            sed -i '' "/^## \[Unreleased\]$/a\\
\\
## [$NEW_VERSION] - $TODAY\\
\\
Build $NEW_BUILD\\
" "$CHANGELOG_PATH"
        else
            # Linux
            sed -i "/^## \[Unreleased\]$/a\\\n## [$NEW_VERSION] - $TODAY\n\nBuild $NEW_BUILD\n" "$CHANGELOG_PATH"
        fi
        echo -e "  ${GREEN}Added [$NEW_VERSION] - $TODAY section${NC}"
    else
        # No unreleased content, just add version header after [Unreleased]
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' "/^## \[Unreleased\]$/a\\
\\
## [$NEW_VERSION] - $TODAY\\
\\
Build $NEW_BUILD\\
" "$CHANGELOG_PATH"
        else
            sed -i "/^## \[Unreleased\]$/a\\\n## [$NEW_VERSION] - $TODAY\n\nBuild $NEW_BUILD\n" "$CHANGELOG_PATH"
        fi
        echo -e "  ${GREEN}Added [$NEW_VERSION] - $TODAY section (no unreleased changes)${NC}"
    fi

    # Update the comparison links at the bottom of CHANGELOG
    REPO_URL="https://github.com/DrBenedictPorkins/NotOurGroceries"

    # Update [Unreleased] link to compare from new version
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s|\[Unreleased\]:.*|[Unreleased]: $REPO_URL/compare/v$NEW_VERSION-$NEW_BUILD...HEAD|" "$CHANGELOG_PATH"

        # Add link for new version if it doesn't exist
        if ! grep -q "^\[$NEW_VERSION\]:" "$CHANGELOG_PATH"; then
            # Find the line with [Unreleased]: and add new version link after it
            sed -i '' "/^\[Unreleased\]:/a\\
[$NEW_VERSION]: $REPO_URL/releases/tag/v$NEW_VERSION-$NEW_BUILD" "$CHANGELOG_PATH"
        fi
    else
        sed -i "s|\[Unreleased\]:.*|[Unreleased]: $REPO_URL/compare/v$NEW_VERSION-$NEW_BUILD...HEAD|" "$CHANGELOG_PATH"

        if ! grep -q "^\[$NEW_VERSION\]:" "$CHANGELOG_PATH"; then
            sed -i "/^\[Unreleased\]:/a[$NEW_VERSION]: $REPO_URL/releases/tag/v$NEW_VERSION-$NEW_BUILD" "$CHANGELOG_PATH"
        fi
    fi

    echo -e "  ${GREEN}Updated version comparison links${NC}"
else
    echo -e "  ${YELLOW}Warning: CHANGELOG.md not found, skipping changelog update${NC}"
fi

# Git operations
echo ""
echo "Committing changes..."

cd "$PROJECT_ROOT"
git add -A

COMMIT_MSG="Release v$NEW_VERSION (build $NEW_BUILD)"
git commit -m "$COMMIT_MSG"

echo -e "  ${GREEN}Created commit: $COMMIT_MSG${NC}"

echo ""
echo "Creating annotated tag..."

TAG_NAME="v$NEW_VERSION-$NEW_BUILD"
TAG_MSG="Release v$NEW_VERSION (build $NEW_BUILD)"
git tag -a "$TAG_NAME" -m "$TAG_MSG"

echo -e "  ${GREEN}Created tag: $TAG_NAME${NC}"

# Print summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Release v$NEW_VERSION (build $NEW_BUILD) prepared!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Summary:"
echo "  Old version: $CURRENT_VERSION (build $CURRENT_BUILD)"
echo "  New version: $NEW_VERSION (build $NEW_BUILD)"
echo "  Git tag: $TAG_NAME"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Review the changes:"
echo "     git log -1 --stat"
echo "     git show $TAG_NAME"
echo ""
echo "  2. Push to remote:"
echo "     git push origin main --tags"
echo ""
echo "  3. Archive and upload to TestFlight:"
echo "     - Open Xcode: GroceryApp.xcodeproj"
echo "     - Select 'Any iOS Device' as destination"
echo "     - Product > Archive"
echo "     - Distribute App > App Store Connect"
echo ""
