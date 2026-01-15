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

After schema changes, deploy with:
```bash
cd /Users/makram/Swift/NotOurGroceries
npx ampx sandbox  # for development
# or
npx ampx deploy   # for production
```
