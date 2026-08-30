#!/bin/bash
# iOS release script — standard versioning convention:
#   - main always tracks the NEXT version under development
#   - tags mark actual releases (semver: v1.1.0)
#   - build numbers are datetime-based, stamped by CI (never by this script)
#   - normal releases bump minor; hotfixes use --next none on a patch branch
#
# Usage:
#   ./scripts/release.sh              # release current version, bump main to next minor
#   ./scripts/release.sh --next major # release current version, bump main to next major
#   ./scripts/release.sh --next patch # release current version, bump main to next patch
#   ./scripts/release.sh --next none  # release current version only — no next-version commit (hotfix)
#   ./scripts/release.sh --dry-run   # preview without making changes

set -e

NEXT_BUMP="minor"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --next) NEXT_BUMP="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PBXPROJ=$(find "$PROJECT_ROOT" -name "project.pbxproj" -maxdepth 3 | head -1)
CHANGELOG="$PROJECT_ROOT/CHANGELOG.md"

# ── Read current version ────────────────────────────────────────────────────
CURRENT=$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" | sed 's/.*= //;s/;//;s/ //g;s/"//g')
IFS='.' read -ra V <<< "$CURRENT"
MAJOR=${V[0]:-1}; MINOR=${V[1]:-0}; PATCH=${V[2]:-0}

# ── Validate semver ─────────────────────────────────────────────────────────
if ! [[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: MARKETING_VERSION '$CURRENT' is not semver (expected X.Y.Z)"
  exit 1
fi

TAG="v$CURRENT"
TODAY=$(date +%Y-%m-%d)

# ── Calculate next version ───────────────────────────────────────────────────
case $NEXT_BUMP in
  minor) NEXT="$MAJOR.$((MINOR+1)).0" ;;
  major) NEXT="$((MAJOR+1)).0.0" ;;
  patch) NEXT="$MAJOR.$MINOR.$((PATCH+1))" ;;
  none)  NEXT="" ;;
  *) echo "Unknown --next value: $NEXT_BUMP (use minor|major|patch|none)"; exit 1 ;;
esac

echo "Releasing:  $CURRENT  →  tag $TAG"
[[ -n "$NEXT" ]] && echo "Next on main: $NEXT"
echo ""

if $DRY_RUN; then
  echo "[dry-run] no changes made"
  exit 0
fi

# ── Ensure clean working tree ────────────────────────────────────────────────
if ! git -C "$PROJECT_ROOT" diff --quiet HEAD 2>/dev/null; then
  echo "Error: uncommitted changes present. Commit or stash first."
  exit 1
fi

# ── Update CHANGELOG ─────────────────────────────────────────────────────────
if [[ -f "$CHANGELOG" ]]; then
  python3 - <<EOF
import re

with open('$CHANGELOG', 'r') as f:
    content = f.read()

# Insert new version section after [Unreleased] header
content = content.replace(
    '## [Unreleased]',
    '## [Unreleased]\n\n## [$CURRENT] - $TODAY',
    1
)

# Update [Unreleased] comparison link
REPO_URL = '$(git -C "$PROJECT_ROOT" remote get-url origin | sed "s/git@github.com:/https:\/\/github.com\//" | sed "s/\.git$//")'
content = re.sub(
    r'\[Unreleased\]:.*',
    f'[Unreleased]: {REPO_URL}/compare/$TAG...HEAD\n[$CURRENT]: {REPO_URL}/releases/tag/$TAG',
    content
)

with open('$CHANGELOG', 'w') as f:
    f.write(content)
EOF
  echo "Updated CHANGELOG.md"
fi

# ── Commit release ───────────────────────────────────────────────────────────
# Only the two files a release actually changes. This used to be `add -A`, which
# swept whatever happened to be sitting untracked in the tree into the tagged
# commit — a release is the one commit that should contain no surprises.
git -C "$PROJECT_ROOT" add "$CHANGELOG" "$PBXPROJ"
git -C "$PROJECT_ROOT" commit -m "Release $TAG"
git -C "$PROJECT_ROOT" tag -a "$TAG" -m "Release $TAG"
echo "Created tag $TAG"

# ── Bump main to next version ────────────────────────────────────────────────
if [[ -n "$NEXT" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s/MARKETING_VERSION = $CURRENT;/MARKETING_VERSION = $NEXT;/g" "$PBXPROJ"
    sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = 0/g" "$PBXPROJ"
  else
    sed -i "s/MARKETING_VERSION = $CURRENT;/MARKETING_VERSION = $NEXT;/g" "$PBXPROJ"
    sed -i "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = 0/g" "$PBXPROJ"
  fi

  git -C "$PROJECT_ROOT" add "$PBXPROJ"
  git -C "$PROJECT_ROOT" commit -m "Begin $NEXT development"
  echo "Main bumped to $NEXT"
fi

echo ""
echo "Push with:  git push origin main --tags"
