# Got Dill - Development Notes

## AWS Configuration

Always use `AWS_PROFILE=mine` before any AWS CLI calls.

## Clear Backend Database (Fresh Start)

> ⚠️ **These scripts target the dead sandbox tables (`nktezw3d…`) and therefore do
> nothing.** Do NOT "fix" them by swapping in the prod suffix
> (`vdsfrt2plzgwfdae2ucpxtwzh4`) — with no sandbox, that deletes the only real
> household data there is. If a genuine wipe is wanted, the user must ask for it
> explicitly, naming production.


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

> ⚠️ Same warning as above — dead sandbox table names, and pointing them at prod
> destroys live data.


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

## DynamoDB Backups (Prod Only)

Point-in-time recovery (PITR) is enabled on all prod tables that hold user data:

| Table | PITR |
|-------|------|
| Aisle | ✅ enabled |
| GroceryItem | ✅ enabled |
| Household | ✅ enabled |
| HouseholdStore | ✅ enabled |
| Product | ✅ enabled |
| ProductAisleMapping | ✅ enabled |
| Store | ✅ enabled |
| User | ✅ enabled |
| AisleExtractionJob | — transient |
| Commit | — transient |
| ShoppingRequest | — transient |

### Restoring a Table

DynamoDB restores to a **new table** — it never overwrites in place. The restore workflow is:

1. Restore source table to a temp table name:
```bash
AWS_PROFILE=mine aws dynamodb restore-table-to-point-in-time \
  --source-table-name "GroceryItem-vdsfrt2plzgwfdae2ucpxtwzh4-NONE" \
  --target-table-name "GroceryItem-vdsfrt2plzgwfdae2ucpxtwzh4-NONE-restored" \
  --restore-date-time "2026-03-02T10:00:00Z"
```

2. Verify the restored data looks correct (scan the temp table)

3. Copy items from temp table back into the live table (scan + batch write), then delete temp table

This approach requires no app redeployment — the live table name never changes. Claude can execute all three steps via CLI when asked.

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

### Environment — there is only one

**There is NO sandbox. Every build configuration talks to production.**

| | |
|---|---|
| Config file | `amplify_outputs_prod.json` |
| Cognito pool | `us-east-1_OIBNTn0XB` |
| AppSync API id | `vdsfrt2plzgwfdae2ucpxtwzh4` |
| DynamoDB table suffix | `-vdsfrt2plzgwfdae2ucpxtwzh4-NONE` |

The app has **2 users** because it is an internal beta. A second environment cost
money, went stale constantly, and every drift between the two schemas cost a
debugging session. It was removed on 2026-08-26 along with the `#if DEBUG` branch
in `AmplifyService.swift`.

**Do not propose creating, deploying to, or "testing first on" a sandbox.**
Schema changes go straight to prod by pushing `main`.

Debug builds write to real household data. That is intentional — there is no
"safe" environment, so think before running anything destructive.

Dead artifacts that still exist and should be ignored: `amplify_outputs_dev.json`,
the `nktezw3d6vcl5jbk7n44jku4e4` API, and its DynamoDB tables.

### Amplify Console

- **App ID**: `d2rsreno8nimo5`
- **Console URL**: https://us-east-1.console.aws.amazon.com/amplify/apps/d2rsreno8nimo5
- **Hosted URL**: https://main.d2rsreno8nimo5.amplifyapp.com/
- **GitHub Repo**: https://github.com/DrBenedictPorkins/NotOurGroceries

### Deployment Commands

```bash
# Fetch latest production config after Amplify Console deployment
AWS_PROFILE=mine npx ampx generate outputs --app-id d2rsreno8nimo5 --branch main

# Push changes to trigger production deployment
git push origin main  # Amplify Console auto-deploys on push
```

### Important Notes

- **Config files are gitignored**: `amplify_outputs*.json` files are in `.gitignore`
- **No staging step**: pushing `main` deploys the live backend the phones use

### Lambda Secrets

Lambda functions read API keys via `secret('NAME')` in their `resource.ts`, resolved from SSM at runtime. Set per environment in the Amplify Console (App settings → Secrets) or via CLI.

| Secret | Used by | Purpose |
|---|---|---|
| `ANTHROPIC_API_KEY` | `parseIngredientsFunction`, `inferProductAisleFunction`, `aisleExtractionJobHandler` | Claude API for parsing, aisle inference, OCR |
| `OPENAI_API_KEY` | `transcribeAudioFunction` | OpenAI Whisper for voice-to-text dictation |

Where to set:
- **Production (CLI)**: Amplify Gen 2 secrets live in AWS SSM. Set directly:
  ```bash
  AWS_PROFILE=mine aws ssm put-parameter \
    --name "/amplify/d2rsreno8nimo5/main/SECRET_NAME" \
    --value "..." \
    --type SecureString --overwrite --region us-east-1
  ```
  Read back with `aws ssm get-parameter --name ... --with-decryption`. Picked up on next Lambda cold start.
- **Production (UI)**: Amplify Console → App → `main` branch → App settings → Secrets.

## Release Order — CRITICAL

**NEVER commit, bump version, or deploy unless explicitly told to.**

When the user says to release/deploy, do it in this exact order:

1. Bump build number + update CHANGELOG.md
2. Commit + tag (`v1.0-N`) + `git push origin main --tags`
3. Tell user to **Archive in Xcode → Distribute to TestFlight**
4. Done — Amplify backend deploys automatically on push, no need to monitor it

**Never** monitor the Amplify deployment or wait for it — it's automatic and not the priority. The iOS archive is what ships to users.

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
