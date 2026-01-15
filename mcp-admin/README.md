# NOG Admin MCP Server

A local MCP (Model Context Protocol) shim that bridges Claude Code to the NotOurGroceries admin Lambda function.

## Setup

1. Install dependencies:
   ```bash
   npm install
   ```

2. Configure Claude Code by adding to `~/.claude.json` or project's `.mcp.json`:
   ```json
   {
     "mcpServers": {
       "nog-admin": {
         "command": "npx",
         "args": ["tsx", "/Users/makram/Swift/NotOurGroceries/mcp-admin/src/index.ts"],
         "env": {
           "ADMIN_LAMBDA_NAME": "your-lambda-function-name",
           "AWS_PROFILE": "mine",
           "AWS_REGION": "us-east-1"
         }
       }
     }
   }
   ```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ADMIN_LAMBDA_NAME` | Yes | - | The name of the admin Lambda function |
| `AWS_REGION` | No | `us-east-1` | AWS region where Lambda is deployed |
| `AWS_PROFILE` | No | - | AWS profile to use (set in .mcp.json) |

## Available Tools

| Tool | Description | Arguments |
|------|-------------|-----------|
| `list_tables` | List all DynamoDB tables | None |
| `list_users` | List all users | None |
| `list_households` | List all households | None |
| `get_household` | Get household details | `householdId` |
| `list_items` | List grocery items | `householdId`, `status?` |
| `get_commits` | Get sync commit history | `householdId`, `limit?` |
| `delete_item` | Delete a grocery item | `itemId` |
| `clear_shopping_data` | Clear all shopping data | `confirm: true` |

## Development

Run the server directly for testing:
```bash
ADMIN_LAMBDA_NAME=your-function-name npm start
```

The server communicates via stdio and expects MCP protocol messages.
