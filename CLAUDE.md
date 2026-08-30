# Got Dill? - Development Notes

## AWS Configuration

Always use `AWS_PROFILE=mine` before any AWS CLI calls.

## Clearing data

There is no script here on purpose. The two that used to live in this section
targeted the sandbox tables, which no longer exist — they were harmless while
they silently did nothing, and became a trap the moment somebody "fixed" them by
swapping in the prod suffix.

There is one environment and it holds one live household. Anything destructive is
a deliberate, case-by-case job against named tables, with the live household id
on a protect list. Ask before running one.

The `nog-admin` MCP server has read tools plus `clear_shopping_data`, and points
at the **prod** admin Lambda (`amplify-d2rsreno8nimo5-ma-adminMcpFunctionlambdaB0-…`).
It was pointed at the sandbox Lambda until 2026-08-30, which meant it reported a
completely different set of households and users than the app was using.

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

The old `nktezw3d6vcl5jbk7n44jku4e4` sandbox was deleted on 2026-08-30 — tables,
AppSync API and CloudFormation stack. It had drifted into a second, plausible set
of households and users that tooling could read and mistake for production.
`amplify_outputs_dev.json` may still be lying around; it points at nothing.

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

1. Write the release notes into `CHANGELOG.md` under `[Unreleased]`
2. Commit everything — the script refuses to run on a dirty tree
3. `./scripts/release.sh` — moves `[Unreleased]` to the version, commits, tags
   `vX.Y.Z`, then bumps `main` to the next minor
4. `git push origin main --tags`
5. Done. The tag push runs `.github/workflows/testflight.yml`, which stamps a
   datetime build number and ships to TestFlight on its own.

**Never** monitor the Amplify deployment or wait for it — it's automatic and not the priority. The tag push is what ships to users.

## Release Workflow

### Version Numbers

- **Marketing Version** (`MARKETING_VERSION`): User-visible version like 1.0.0
- **Build Number** (`CURRENT_PROJECT_VERSION`): Increments with each TestFlight upload
- **Git Tags**: Format is `v{VERSION}-{BUILD}` (e.g., `v1.0.0-1`)

### How the script actually works

`main` always carries the **next** version under development. Tags mark what
shipped. So releasing 1.6.0 tags `v1.6.0` and leaves `main` on 1.7.0.

```bash
./scripts/release.sh              # release current version, bump main to next minor
./scripts/release.sh --next major # ...bump to next major instead
./scripts/release.sh --next patch # ...next patch
./scripts/release.sh --next none  # release only, no bump commit (hotfix branch)
./scripts/release.sh --dry-run    # print what it would do
```

There is no `--bump-build`, `--bump-minor`, `--bump-patch` or `--bump-major`;
this section documented those flags for months and none of them ever existed.

**Build numbers are never set by hand or by the script.** `CURRENT_PROJECT_VERSION`
sits at `0` in the repo and CI stamps a datetime into it
(`.github/workflows/testflight.yml`). A build made locally therefore reports
build 0, which is correct rather than broken.

### Release

```bash
# 1. CHANGELOG.md — fill in [Unreleased]
# 2. commit everything; the script refuses a dirty tree
./scripts/release.sh
git push origin main --tags
# The tag push builds and uploads to TestFlight. Nothing to do in Xcode.
```

### Current Release

- **Latest**: v1.6.0 (August 30, 2026)
- See `CHANGELOG.md` for full history
