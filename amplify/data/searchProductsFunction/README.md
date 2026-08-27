# Search Products Function

Lambda handler for fuzzy product search in the Got Dill app.

## Features

### Multi-tier Search Strategy

1. **Exact Match**: First attempts to find products with exact normalized name match
2. **Prefix Match**: Falls back to products whose names begin with the query
3. **Fuzzy Match**: Scans products and uses Levenshtein distance for fuzzy matching

### Similarity Scoring

- **Levenshtein Distance**: Measures edit distance between strings
- **Score Boosting**:
  - Exact match: 1.0 (perfect score)
  - Prefix match: 0.95
  - Contains match: 0.85 minimum
  - Fuzzy matches: Based on edit distance
- **Alias Support**: Checks product aliases and uses the best score
- **Threshold**: Filters out matches with score < 0.3

### Arguments

- `query` (string, required): Search query
- `limit` (number, optional, default: 10): Maximum number of results to return

### Environment Variables

- `PRODUCT_TABLE_NAME`: DynamoDB table name for products

## Implementation Details

The handler uses:
- `@aws-sdk/client-dynamodb`: DynamoDB client
- `@aws-sdk/lib-dynamodb`: Document client for easier DynamoDB operations
- Custom Levenshtein distance algorithm for fuzzy matching (no external dependencies)

## Performance Considerations

- Exact and prefix matches use DynamoDB GSI for fast queries
- Fuzzy scan is limited to 100 items to avoid timeouts
- Results are sorted by relevance score
- Configurable result limit to control response size
