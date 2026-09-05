import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { LambdaClient, InvokeCommand } from "@aws-sdk/client-lambda";

// Initialize Lambda client
const lambda = new LambdaClient({
  region: process.env.AWS_REGION || "us-east-1",
});

const LAMBDA_FUNCTION_NAME = process.env.ADMIN_LAMBDA_NAME;

if (!LAMBDA_FUNCTION_NAME) {
  console.error("Error: ADMIN_LAMBDA_NAME environment variable is required");
  process.exit(1);
}

// Define the tools that map to Lambda operations
const tools = [
  {
    name: "list_tables",
    description: "List all DynamoDB tables for the Got Dill backend",
    inputSchema: {
      type: "object" as const,
      properties: {},
      required: [],
    },
  },
  {
    name: "list_users",
    description: "List all users in the system",
    inputSchema: {
      type: "object" as const,
      properties: {},
      required: [],
    },
  },
  {
    name: "list_households",
    description: "List all households in the system",
    inputSchema: {
      type: "object" as const,
      properties: {},
      required: [],
    },
  },
  {
    name: "get_household",
    description: "Get detailed information about a specific household including members and stores",
    inputSchema: {
      type: "object" as const,
      properties: {
        householdId: {
          type: "string",
          description: "The ID of the household to retrieve",
        },
      },
      required: ["householdId"],
    },
  },
  {
    name: "list_items",
    description: "List grocery items for a household, optionally filtered by status",
    inputSchema: {
      type: "object" as const,
      properties: {
        householdId: {
          type: "string",
          description: "The ID of the household",
        },
        status: {
          type: "string",
          description: "Filter by status: ACTIVE, IN_CART, or SUGGESTION",
          enum: ["ACTIVE", "IN_CART", "SUGGESTION"],
        },
      },
      required: ["householdId"],
    },
  },
  {
    name: "get_commits",
    description: "Get commit history for a household (sync operations)",
    inputSchema: {
      type: "object" as const,
      properties: {
        householdId: {
          type: "string",
          description: "The ID of the household",
        },
        limit: {
          type: "number",
          description: "Maximum number of commits to return (default: 20)",
        },
      },
      required: ["householdId"],
    },
  },
  {
    name: "delete_item",
    description: "Delete a specific grocery item by ID",
    inputSchema: {
      type: "object" as const,
      properties: {
        itemId: {
          type: "string",
          description: "The ID of the item to delete",
        },
      },
      required: ["itemId"],
    },
  },
  {
    name: "clear_shopping_data",
    description: "Clear all shopping data (items, commits, requests) while preserving users and households. Requires confirmation.",
    inputSchema: {
      type: "object" as const,
      properties: {
        confirm: {
          type: "boolean",
          description: "Must be true to confirm the destructive operation",
        },
      },
      required: ["confirm"],
    },
  },
  {
    name: "get_allowances",
    description: "A household's entitlement (FREE, SUBSCRIBED, COMPED), what it has used this period, the caps, and when the period resets.",
    inputSchema: {
      type: "object" as const,
      properties: {
        householdId: { type: "string", description: "Household ID" },
      },
      required: ["householdId"],
    },
  },
  {
    name: "comp_household",
    description: "Mark a household COMPED: every allowance lifted, no receipt. For friends, testers and the live household.",
    inputSchema: {
      type: "object" as const,
      properties: {
        householdId: { type: "string", description: "Household ID" },
      },
      required: ["householdId"],
    },
  },
  {
    name: "uncomp_household",
    description: "Return a comped household to FREE. Counters are kept; the caps apply again.",
    inputSchema: {
      type: "object" as const,
      properties: {
        householdId: { type: "string", description: "Household ID" },
      },
      required: ["householdId"],
    },
  },
];

// Create MCP server
const server = new Server(
  {
    name: "nog-admin-mcp",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// Handle list tools request
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return { tools };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    // Invoke the Lambda function
    const command = new InvokeCommand({
      FunctionName: LAMBDA_FUNCTION_NAME,
      Payload: JSON.stringify({ tool: name, args: args || {} }),
    });

    const response = await lambda.send(command);

    // Check for Lambda invocation errors
    if (response.FunctionError) {
      const errorPayload = response.Payload
        ? JSON.parse(new TextDecoder().decode(response.Payload))
        : { errorMessage: "Unknown Lambda error" };

      return {
        content: [
          {
            type: "text" as const,
            text: `Lambda error: ${errorPayload.errorMessage || errorPayload.errorType || "Unknown error"}`,
          },
        ],
        isError: true,
      };
    }

    // Parse the Lambda response
    if (!response.Payload) {
      return {
        content: [
          {
            type: "text" as const,
            text: "Lambda returned no payload",
          },
        ],
        isError: true,
      };
    }

    const payloadString = new TextDecoder().decode(response.Payload);
    const result = JSON.parse(payloadString);

    // Handle Lambda application-level errors
    if (result.error) {
      return {
        content: [
          {
            type: "text" as const,
            text: `Error: ${result.error}`,
          },
        ],
        isError: true,
      };
    }

    // Return successful result
    return {
      content: [
        {
          type: "text" as const,
          text: typeof result === "string" ? result : JSON.stringify(result, null, 2),
        },
      ],
    };
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    return {
      content: [
        {
          type: "text" as const,
          text: `Failed to invoke Lambda: ${errorMessage}`,
        },
      ],
      isError: true,
    };
  }
});

// Start the server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("NOG Admin MCP server running on stdio");
}

main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
