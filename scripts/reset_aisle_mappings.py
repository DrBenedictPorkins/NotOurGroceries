#!/usr/bin/env python3
"""
Reset/Clear ProductAisleMapping data for development/debugging.

This script only affects ProductAisleMapping records - it does NOT touch:
- Users, Profiles
- Households
- GroceryItems
- Products (community list)
- Stores

Usage:
    python scripts/reset_aisle_mappings.py --all              # Clear ALL mappings
    python scripts/reset_aisle_mappings.py --store STORE_ID   # Clear mappings for specific store
    python scripts/reset_aisle_mappings.py --list             # List all mappings (dry run)
    python scripts/reset_aisle_mappings.py --stats            # Show stats only
"""

import boto3
import json
import argparse
from datetime import datetime

# Load Amplify outputs to get table name
def load_amplify_config():
    with open('amplify_outputs.json', 'r') as f:
        config = json.load(f)

    # Get the DynamoDB table name for ProductAisleMapping
    # Table name pattern: ProductAisleMapping-{api_id}-{branch}
    api_id = config.get('data', {}).get('api_id', '')

    # The table name is typically in the format: ProductAisleMapping-{random}-NONE
    return api_id

def get_dynamodb_client():
    return boto3.client('dynamodb', region_name='us-east-1')

def get_table_name():
    """Get the ProductAisleMapping table name from AWS."""
    client = boto3.client('dynamodb', region_name='us-east-1')

    # List tables and find the one matching ProductAisleMapping
    tables = client.list_tables()['TableNames']
    for table in tables:
        if 'ProductAisleMapping' in table:
            return table

    raise ValueError("ProductAisleMapping table not found. Available tables: " + str(tables))

def list_mappings(table_name, store_id=None):
    """List all mappings, optionally filtered by store."""
    client = get_dynamodb_client()

    params = {'TableName': table_name}

    if store_id:
        params['FilterExpression'] = 'storeId = :sid'
        params['ExpressionAttributeValues'] = {':sid': {'S': store_id}}

    mappings = []
    while True:
        response = client.scan(**params)
        mappings.extend(response.get('Items', []))

        if 'LastEvaluatedKey' not in response:
            break
        params['ExclusiveStartKey'] = response['LastEvaluatedKey']

    return mappings

def delete_mappings(table_name, mappings):
    """Delete the specified mappings."""
    client = get_dynamodb_client()

    deleted = 0
    for mapping in mappings:
        item_id = mapping['id']['S']
        try:
            client.delete_item(
                TableName=table_name,
                Key={'id': {'S': item_id}}
            )
            deleted += 1
            print(f"  Deleted: {mapping.get('normalizedName', {}).get('S', item_id)}")
        except Exception as e:
            print(f"  Error deleting {item_id}: {e}")

    return deleted

def show_stats(table_name):
    """Show statistics about current mappings."""
    mappings = list_mappings(table_name)

    # Group by store
    by_store = {}
    by_source = {'IMAGE': 0, 'LLM_GUESS': 0, 'unknown': 0}
    low_confidence = 0
    with_override = 0

    for m in mappings:
        store_id = m.get('storeId', {}).get('S', 'unknown')
        by_store[store_id] = by_store.get(store_id, 0) + 1

        source = m.get('source', {}).get('S', 'unknown')
        by_source[source] = by_source.get(source, 0) + 1

        confidence = float(m.get('confidence', {}).get('N', '1.0'))
        if confidence < 0.7:
            low_confidence += 1

        if m.get('userAisleOverride', {}).get('S'):
            with_override += 1

    print("\n=== ProductAisleMapping Statistics ===\n")
    print(f"Total mappings: {len(mappings)}")
    print(f"Low confidence (<70%): {low_confidence}")
    print(f"User overrides: {with_override}")
    print(f"\nBy source:")
    for source, count in by_source.items():
        if count > 0:
            print(f"  {source}: {count}")
    print(f"\nBy store:")
    for store_id, count in by_store.items():
        print(f"  {store_id[:20]}...: {count}")

def main():
    parser = argparse.ArgumentParser(description='Reset ProductAisleMapping data')
    parser.add_argument('--all', action='store_true', help='Clear ALL mappings')
    parser.add_argument('--store', type=str, help='Clear mappings for specific store ID')
    parser.add_argument('--list', action='store_true', help='List mappings (dry run)')
    parser.add_argument('--stats', action='store_true', help='Show statistics only')
    parser.add_argument('--yes', '-y', action='store_true', help='Skip confirmation')

    args = parser.parse_args()

    if not any([args.all, args.store, args.list, args.stats]):
        parser.print_help()
        return

    print("Finding ProductAisleMapping table...")
    table_name = get_table_name()
    print(f"Table: {table_name}\n")

    if args.stats:
        show_stats(table_name)
        return

    # Get mappings
    mappings = list_mappings(table_name, args.store)

    if args.list:
        print(f"Found {len(mappings)} mappings:\n")
        for m in mappings[:50]:  # Show first 50
            name = m.get('normalizedName', {}).get('S', 'N/A')
            aisle = m.get('aisleId', {}).get('S', 'N/A')
            confidence = m.get('confidence', {}).get('N', 'N/A')
            source = m.get('source', {}).get('S', 'N/A')
            override = m.get('userAisleOverride', {}).get('S', '')

            override_str = f" [override: {override}]" if override else ""
            print(f"  {name} -> {aisle} ({confidence}%, {source}){override_str}")

        if len(mappings) > 50:
            print(f"\n  ... and {len(mappings) - 50} more")
        return

    if args.all or args.store:
        scope = f"store {args.store}" if args.store else "ALL stores"
        print(f"Found {len(mappings)} mappings for {scope}")

        if len(mappings) == 0:
            print("Nothing to delete.")
            return

        if not args.yes:
            confirm = input(f"\nDelete {len(mappings)} mappings? (yes/no): ")
            if confirm.lower() != 'yes':
                print("Aborted.")
                return

        print("\nDeleting mappings...")
        deleted = delete_mappings(table_name, mappings)
        print(f"\nDeleted {deleted} mappings.")

if __name__ == '__main__':
    main()
