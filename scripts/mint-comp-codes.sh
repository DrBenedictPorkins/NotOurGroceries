#!/bin/bash
# Mint comp codes into the CompCode table.
#
# The cap on comped households IS the number of rows here. Mint a hundred and a
# hundred-and-first code cannot be redeemed, because there is nothing to redeem —
# no counter anywhere, so no race to lose.
#
#   ./scripts/mint-comp-codes.sh 100 "launch batch"     mint and print them
#   ./scripts/mint-comp-codes.sh --list                 what exists and who spent it
#
# Codes use the invite alphabet: no O, 0, I or 1, because these get read aloud
# and typed by hand.
set -euo pipefail

TABLE="CompCode-vdsfrt2plzgwfdae2ucpxtwzh4-NONE"
REGION="us-east-1"
export AWS_PROFILE="${AWS_PROFILE:-mine}"

if [ "${1:-}" = "--list" ]; then
  aws dynamodb scan --table-name "$TABLE" --region "$REGION" \
    --projection-expression "code, redeemedByHouseholdId, redeemedAt, note" \
    --query 'Items[].[code.S, redeemedByHouseholdId.S, redeemedAt.S, note.S]' \
    --output text | sort
  echo "---"
  echo -n "total: "; aws dynamodb scan --table-name "$TABLE" --region "$REGION" --select COUNT --query 'Count' --output text
  exit 0
fi

COUNT="${1:-}"
NOTE="${2:-}"
if ! [[ "$COUNT" =~ ^[0-9]+$ ]] || [ "$COUNT" -lt 1 ] || [ "$COUNT" -gt 200 ]; then
  echo "usage: $0 <count 1-200> [note]   |   $0 --list" >&2
  exit 1
fi

EXISTING=$(aws dynamodb scan --table-name "$TABLE" --region "$REGION" --select COUNT --query 'Count' --output text)
echo "$EXISTING code(s) already minted. Adding $COUNT."
read -r -p "Continue? [y/N] " ok
[ "$ok" = "y" ] || { echo "aborted"; exit 1; }

NOW=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
ALPHABET="ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

minted=0
while [ "$minted" -lt "$COUNT" ]; do
  CODE=""
  for _ in $(seq 1 8); do
    IDX=$(( RANDOM % ${#ALPHABET} ))
    CODE="$CODE${ALPHABET:$IDX:1}"
  done

  # attribute_not_exists is what makes a collision a no-op rather than an
  # overwrite of a code somebody already holds.
  if aws dynamodb put-item --table-name "$TABLE" --region "$REGION" \
      --condition-expression "attribute_not_exists(code)" \
      --item "{
        \"code\": {\"S\": \"$CODE\"},
        \"note\": {\"S\": \"$NOTE\"},
        \"createdAt\": {\"S\": \"$NOW\"},
        \"updatedAt\": {\"S\": \"$NOW\"},
        \"__typename\": {\"S\": \"CompCode\"}
      }" >/dev/null 2>&1; then
    echo "$CODE"
    minted=$((minted + 1))
  fi
done

echo "---"
echo "minted $minted"
