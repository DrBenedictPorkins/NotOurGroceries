# NotOurGroceries - Development Notes

## AWS Configuration

Always use `AWS_PROFILE=mine` before any AWS CLI calls.

## Clear Backend Database (Fresh Start)

When schema changes require a fresh start, run this to clear all DynamoDB tables:

```bash
AWS_PROFILE=mine bash << 'EOF'
TABLES=(
  "Aisle-nktezw3d6vcl5jbk7n44jku4e4-NONE"
  "Commit-nktezw3d6vcl5jbk7n44jku4e4-NONE"
  "GroceryItem-nktezw3d6vcl5jbk7n44jku4e4-NONE"
  "Household-nktezw3d6vcl5jbk7n44jku4e4-NONE"
  "HouseholdStore-nktezw3d6vcl5jbk7n44jku4e4-NONE"
  "ProductAisleMapping-nktezw3d6vcl5jbk7n44jku4e4-NONE"
  "ShoppingRequest-nktezw3d6vcl5jbk7n44jku4e4-NONE"
  "Store-nktezw3d6vcl5jbk7n44jku4e4-NONE"
  "User-nktezw3d6vcl5jbk7n44jku4e4-NONE"
)

# Note: Skipping Product table - contains community catalog data (239 products)

for TABLE in "${TABLES[@]}"; do
  echo "Clearing table: $TABLE"

  KEY_SCHEMA=$(aws dynamodb describe-table --table-name "$TABLE" --query "Table.KeySchema" --output json)
  HASH_KEY=$(echo "$KEY_SCHEMA" | jq -r '.[] | select(.KeyType=="HASH") | .AttributeName')
  RANGE_KEY=$(echo "$KEY_SCHEMA" | jq -r '.[] | select(.KeyType=="RANGE") | .AttributeName // empty')

  if [ -z "$RANGE_KEY" ]; then
    ITEMS=$(aws dynamodb scan --table-name "$TABLE" --projection-expression "$HASH_KEY" --output json)
  else
    ITEMS=$(aws dynamodb scan --table-name "$TABLE" --projection-expression "$HASH_KEY, $RANGE_KEY" --output json)
  fi

  COUNT=$(echo "$ITEMS" | jq '.Items | length')
  echo "  Found $COUNT items"

  echo "$ITEMS" | jq -c '.Items[]' | while read -r item; do
    aws dynamodb delete-item --table-name "$TABLE" --key "$item" 2>/dev/null
  done

  echo "  Done"
done

echo "All tables cleared!"
EOF
```

## Clear Shopping Data Only (Keep Users & Households)

Clears shopping lists, history, and requests while preserving user accounts and household setup:

```bash
AWS_PROFILE=mine bash << 'EOF'
TABLES=(
  "GroceryItem-nktezw3d6vcl5jbk7n44jku4e4-NONE"
  "Commit-nktezw3d6vcl5jbk7n44jku4e4-NONE"
  "ShoppingRequest-nktezw3d6vcl5jbk7n44jku4e4-NONE"
)

# Preserves: User, Household, HouseholdStore, ProductAisleMapping, Product, Store, Aisle

for TABLE in "${TABLES[@]}"; do
  echo "Clearing table: $TABLE"

  KEY_SCHEMA=$(aws dynamodb describe-table --table-name "$TABLE" --query "Table.KeySchema" --output json)
  HASH_KEY=$(echo "$KEY_SCHEMA" | jq -r '.[] | select(.KeyType=="HASH") | .AttributeName')
  RANGE_KEY=$(echo "$KEY_SCHEMA" | jq -r '.[] | select(.KeyType=="RANGE") | .AttributeName // empty')

  if [ -z "$RANGE_KEY" ]; then
    ITEMS=$(aws dynamodb scan --table-name "$TABLE" --projection-expression "$HASH_KEY" --output json)
  else
    ITEMS=$(aws dynamodb scan --table-name "$TABLE" --projection-expression "$HASH_KEY, $RANGE_KEY" --output json)
  fi

  COUNT=$(echo "$ITEMS" | jq '.Items | length')
  echo "  Found $COUNT items"

  echo "$ITEMS" | jq -c '.Items[]' | while read -r item; do
    aws dynamodb delete-item --table-name "$TABLE" --key "$item" 2>/dev/null
  done

  echo "  Done"
done

echo "Shopping data cleared!"
EOF
```

## Data Model

### ItemStatus Enum
- `ACTIVE` - Item on shopping list (to buy)
- `IN_CART` - Item picked up during current shopping trip
- `SUGGESTION` - Item from previous trips (available to add to list)

### State Transitions

| Phase | Action | Status Change |
|-------|--------|---------------|
| List Building | Add item | → `ACTIVE` |
| List Building | Move to suggestions | `ACTIVE` → `SUGGESTION` |
| List Building | Move to list | `SUGGESTION` → `ACTIVE` |
| Active Shopping | Cross off | `ACTIVE` → `IN_CART` |
| Active Shopping | Restore | `IN_CART` → `ACTIVE` |
| Done Shopping | All in-cart items | `IN_CART` → `SUGGESTION` |
| Done Shopping | Uncrossed items | `ACTIVE` → `SUGGESTION` |

### Shopping Phases
- **IDLE** - List building mode, all members can edit freely
- **AT_STORE** - Active shopping, one designated shopper

## Amplify Gen 2

Backend schema is defined in `amplify/data/resource.ts`.

### Environments

| Environment | Config File | Cognito Pool | AppSync API |
|-------------|-------------|--------------|-------------|
| **Development** (Debug) | `amplify_outputs_dev.json` | `us-east-1_PWCfwCEUh` | `awxymvwkinht3dofuywc73phwy` |
| **Production** (Release) | `amplify_outputs_prod.json` | `us-east-1_OIBNTn0XB` | `sve64qw4c5cu5jerw6gn2jrvd4` |

### Build Configuration

The iOS app automatically selects the correct backend based on build configuration:
- **Debug builds** (Simulator, development) → Sandbox backend
- **Release builds** (Archive, TestFlight, App Store) → Production backend

This is controlled in `AmplifyService.swift` via `#if DEBUG`.

### Amplify Console

- **App ID**: `d2rsreno8nimo5`
- **Console URL**: https://us-east-1.console.aws.amazon.com/amplify/apps/d2rsreno8nimo5
- **Hosted URL**: https://main.d2rsreno8nimo5.amplifyapp.com/
- **GitHub Repo**: https://github.com/DrBenedictPorkins/NotOurGroceries

### Deployment Commands

```bash
# Development (sandbox) - local watch mode
npx ampx sandbox

# Fetch latest production config after Amplify Console deployment
AWS_PROFILE=mine npx ampx generate outputs --app-id d2rsreno8nimo5 --branch main

# Push changes to trigger production deployment
git push origin main  # Amplify Console auto-deploys on push
```

### Important Notes

- **Separate user pools**: Users must register separately in prod (different Cognito pool)
- **Separate databases**: Prod DynamoDB tables are independent from sandbox
- **Config files are gitignored**: `amplify_outputs*.json` files are in `.gitignore`

## Release Workflow

### Version Numbers

- **Marketing Version** (`MARKETING_VERSION`): User-visible version like 1.0.0
- **Build Number** (`CURRENT_PROJECT_VERSION`): Increments with each TestFlight upload
- **Git Tags**: Format is `v{VERSION}-{BUILD}` (e.g., `v1.0.0-1`)

### Release Checklist

1. Ensure all changes are committed
2. Update `CHANGELOG.md` with changes under `[Unreleased]`
3. Run release script: `./scripts/release.sh --bump-build` (or `--bump-minor`, `--bump-patch`, `--bump-major`)
4. Push to remote: `git push origin main --tags`
5. In Xcode: Product → Archive
6. Distribute: TestFlight Internal Only (or App Store Connect)
7. In App Store Connect: Add build to "Family" testing group

### Version Bump Guide

| Change Type | Command | Example |
|-------------|---------|---------|
| Bug fix, no new features | `--bump-build` | 1.0.0 (1) → 1.0.0 (2) |
| Bug fix release | `--bump-patch` | 1.0.0 → 1.0.1 (1) |
| New features | `--bump-minor` | 1.0.0 → 1.1.0 (1) |
| Breaking changes | `--bump-major` | 1.0.0 → 2.0.0 (1) |

### Quick Release Commands

```bash
# Standard release (just bump build)
./scripts/release.sh --bump-build && git push origin main --tags

# Then in Xcode: Product → Archive → Distribute
```

### Current Release

- **Latest**: v1.0.0-1 (January 18, 2026)
- See `CHANGELOG.md` for full history
