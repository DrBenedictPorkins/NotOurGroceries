import { DynamoDBClient, DescribeTableCommand, ScanCommand, DeleteItemCommand } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, QueryCommand, ScanCommand as DocScanCommand } from '@aws-sdk/lib-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import { setEntitlement, loadAllowance, summarize } from '../allowance';

// ========================================
// TYPES
// ========================================

interface McpToolRequest {
  tool: string;
  args?: Record<string, any>;
}

interface McpToolResponse {
  success: boolean;
  data?: any;
  error?: string;
}

// ========================================
// SETUP
// ========================================

const client = new DynamoDBClient({});
const docClient = DynamoDBDocumentClient.from(client);

// Environment variables for table names
const TABLE_NAMES = {
  user: process.env.USER_TABLE!,
  household: process.env.HOUSEHOLD_TABLE!,
  groceryItem: process.env.GROCERY_ITEM_TABLE!,
  product: process.env.PRODUCT_TABLE!,
  store: process.env.STORE_TABLE!,
  aisle: process.env.AISLE_TABLE!,
  householdStore: process.env.HOUSEHOLD_STORE_TABLE!,
  productAisleMapping: process.env.PRODUCT_AISLE_MAPPING_TABLE!,
  commit: process.env.COMMIT_TABLE!,
  shoppingRequest: process.env.SHOPPING_REQUEST_TABLE!,
};

// ========================================
// TOOL IMPLEMENTATIONS
// ========================================

/**
 * List all DynamoDB tables with their item counts
 */
async function listTables(): Promise<McpToolResponse> {
  try {
    const tableInfo: Record<string, { tableName: string; itemCount: number }> = {};

    for (const [key, tableName] of Object.entries(TABLE_NAMES)) {
      if (!tableName) {
        tableInfo[key] = { tableName: 'NOT_CONFIGURED', itemCount: -1 };
        continue;
      }

      try {
        const result = await client.send(new DescribeTableCommand({ TableName: tableName }));
        tableInfo[key] = {
          tableName,
          itemCount: result.Table?.ItemCount ?? 0,
        };
      } catch (err) {
        tableInfo[key] = { tableName, itemCount: -1 };
      }
    }

    return { success: true, data: tableInfo };
  } catch (error) {
    return { success: false, error: `Failed to list tables: ${error}` };
  }
}

/**
 * List all users with their household associations
 */
async function listUsers(): Promise<McpToolResponse> {
  try {
    const result = await docClient.send(new DocScanCommand({
      TableName: TABLE_NAMES.user,
    }));

    const users = (result.Items ?? []).map(item => ({
      id: item.id,
      email: item.email,
      displayName: item.displayName,
      householdId: item.householdId,
      lastActive: item.lastActive,
      createdAt: item.createdAt,
    }));

    return { success: true, data: { count: users.length, users } };
  } catch (error) {
    return { success: false, error: `Failed to list users: ${error}` };
  }
}

/**
 * List all households with member counts
 */
async function listHouseholds(): Promise<McpToolResponse> {
  try {
    const result = await docClient.send(new DocScanCommand({
      TableName: TABLE_NAMES.household,
    }));

    const households = await Promise.all((result.Items ?? []).map(async (item) => {
      // Count members for this household
      let memberCount = 0;
      try {
        const membersResult = await docClient.send(new QueryCommand({
          TableName: TABLE_NAMES.user,
          IndexName: 'usersByHouseholdId',
          KeyConditionExpression: 'householdId = :hid',
          ExpressionAttributeValues: { ':hid': item.id },
          Select: 'COUNT',
        }));
        memberCount = membersResult.Count ?? 0;
      } catch {
        // Index might not exist or other issue
      }

      return {
        id: item.id,
        name: item.name,
        inviteCode: item.inviteCode,
        shoppingStatus: item.shoppingStatus,
        activeShopperId: item.activeShopperId,
        shoppingStoreId: item.shoppingStoreId,
        sequenceNumber: item.sequenceNumber,
        memberCount,
        createdAt: item.createdAt,
      };
    }));

    return { success: true, data: { count: households.length, households } };
  } catch (error) {
    return { success: false, error: `Failed to list households: ${error}` };
  }
}

/**
 * Get a single household with members, items, and stores
 */
async function getHousehold(args: Record<string, any>): Promise<McpToolResponse> {
  const { householdId } = args;

  if (!householdId) {
    return { success: false, error: 'Missing required argument: householdId' };
  }

  try {
    // Get household
    const householdResult = await docClient.send(new GetCommand({
      TableName: TABLE_NAMES.household,
      Key: { id: householdId },
    }));

    if (!householdResult.Item) {
      return { success: false, error: `Household not found: ${householdId}` };
    }

    const household = householdResult.Item;

    // Get members
    const membersResult = await docClient.send(new QueryCommand({
      TableName: TABLE_NAMES.user,
      IndexName: 'usersByHouseholdId',
      KeyConditionExpression: 'householdId = :hid',
      ExpressionAttributeValues: { ':hid': householdId },
    }));

    const members = (membersResult.Items ?? []).map(item => ({
      id: item.id,
      email: item.email,
      displayName: item.displayName,
      lastActive: item.lastActive,
    }));

    // Get items (scan with filter since GSI uses composite key with status)
    const itemsResult = await docClient.send(new DocScanCommand({
      TableName: TABLE_NAMES.groceryItem,
      FilterExpression: 'householdId = :hid',
      ExpressionAttributeValues: { ':hid': householdId },
    }));

    const items = itemsResult.Items ?? [];
    const itemsByStatus = {
      ACTIVE: items.filter(i => i.status === 'ACTIVE'),
      IN_CART: items.filter(i => i.status === 'IN_CART'),
      SUGGESTION: items.filter(i => i.status === 'SUGGESTION'),
    };

    // Get household stores
    const storesResult = await docClient.send(new QueryCommand({
      TableName: TABLE_NAMES.householdStore,
      IndexName: 'householdStoresByHouseholdId',
      KeyConditionExpression: 'householdId = :hid',
      ExpressionAttributeValues: { ':hid': householdId },
    }));

    const stores = (storesResult.Items ?? []).map(item => ({
      id: item.id,
      name: item.name,
      chain: item.chain,
      address: item.address,
      aisleCount: Array.isArray(item.aisleLayout) ? item.aisleLayout.length : 0,
    }));

    return {
      success: true,
      data: {
        household: {
          id: household.id,
          name: household.name,
          inviteCode: household.inviteCode,
          inviteCodeExpiresAt: household.inviteCodeExpiresAt,
          shoppingStatus: household.shoppingStatus,
          activeShopperId: household.activeShopperId,
          shoppingStoreId: household.shoppingStoreId,
          sequenceNumber: household.sequenceNumber,
          createdAt: household.createdAt,
        },
        members,
        items: {
          total: items.length,
          active: itemsByStatus.ACTIVE.length,
          inCart: itemsByStatus.IN_CART.length,
          suggestions: itemsByStatus.SUGGESTION.length,
        },
        stores,
      },
    };
  } catch (error) {
    return { success: false, error: `Failed to get household: ${error}` };
  }
}

/**
 * List items for a household with optional status filter
 */
async function listItems(args: Record<string, any>): Promise<McpToolResponse> {
  const { householdId, status } = args;

  if (!householdId) {
    return { success: false, error: 'Missing required argument: householdId' };
  }

  try {
    let items: any[];

    if (status) {
      // Use the GSI with status sort key
      const result = await docClient.send(new QueryCommand({
        TableName: TABLE_NAMES.groceryItem,
        IndexName: 'groceryItemsByHouseholdIdAndStatus',
        KeyConditionExpression: 'householdId = :hid AND #status = :status',
        ExpressionAttributeNames: { '#status': 'status' },
        ExpressionAttributeValues: {
          ':hid': householdId,
          ':status': status,
        },
      }));
      items = result.Items ?? [];
    } else {
      // Get all items for household (scan with filter)
      const result = await docClient.send(new DocScanCommand({
        TableName: TABLE_NAMES.groceryItem,
        FilterExpression: 'householdId = :hid',
        ExpressionAttributeValues: { ':hid': householdId },
      }));
      items = result.Items ?? [];
    }

    const formattedItems = items.map(item => ({
      id: item.id,
      name: item.name,
      normalizedName: item.normalizedName,
      quantity: item.quantity,
      notes: item.notes,
      status: item.status,
      productId: item.productId,
      isCustom: item.isCustom,
      addedBy: item.addedBy,
      addedAt: item.addedAt,
      lockedBy: item.lockedBy,
      version: item.version,
    }));

    return {
      success: true,
      data: {
        count: formattedItems.length,
        householdId,
        statusFilter: status || 'ALL',
        items: formattedItems,
      },
    };
  } catch (error) {
    return { success: false, error: `Failed to list items: ${error}` };
  }
}

/**
 * Get commits for a household with optional limit
 */
async function getCommits(args: Record<string, any>): Promise<McpToolResponse> {
  const { householdId, limit = 50 } = args;

  if (!householdId) {
    return { success: false, error: 'Missing required argument: householdId' };
  }

  try {
    const result = await docClient.send(new QueryCommand({
      TableName: TABLE_NAMES.commit,
      IndexName: 'commitsByHouseholdIdAndSequenceNumber',
      KeyConditionExpression: 'householdId = :hid',
      ExpressionAttributeValues: { ':hid': householdId },
      ScanIndexForward: false, // Descending order (newest first)
      Limit: limit,
    }));

    const commits = (result.Items ?? []).map(item => ({
      id: item.id,
      sequenceNumber: item.sequenceNumber,
      author: item.author,
      authorName: item.authorName,
      action: item.action,
      payload: item.payload,
      createdAt: item.createdAt,
    }));

    return {
      success: true,
      data: {
        count: commits.length,
        householdId,
        limit,
        commits,
      },
    };
  } catch (error) {
    return { success: false, error: `Failed to get commits: ${error}` };
  }
}

/**
 * Delete a single grocery item by ID
 */
async function deleteItem(args: Record<string, any>): Promise<McpToolResponse> {
  const { itemId } = args;

  if (!itemId) {
    return { success: false, error: 'Missing required argument: itemId' };
  }

  try {
    await client.send(new DeleteItemCommand({
      TableName: TABLE_NAMES.groceryItem,
      Key: marshall({ id: itemId }),
    }));

    return { success: true, data: { deleted: itemId } };
  } catch (error) {
    return { success: false, error: `Failed to delete item: ${error}` };
  }
}

/**
 * Clear all shopping data (GroceryItem, Commit, ShoppingRequest tables)
 * DANGEROUS: Requires confirmation
 */
async function clearShoppingData(args: Record<string, any>): Promise<McpToolResponse> {
  const { confirm } = args;

  if (confirm !== true) {
    return {
      success: false,
      error: 'DANGEROUS OPERATION: This will delete ALL shopping data (items, commits, requests). Pass { confirm: true } to proceed.',
    };
  }

  const tablesToClear = [
    { name: 'GroceryItem', tableName: TABLE_NAMES.groceryItem },
    { name: 'Commit', tableName: TABLE_NAMES.commit },
    { name: 'ShoppingRequest', tableName: TABLE_NAMES.shoppingRequest },
  ];

  const results: Record<string, { deleted: number; errors: number }> = {};

  for (const { name, tableName } of tablesToClear) {
    let deleted = 0;
    let errors = 0;

    try {
      // Scan all items
      let lastEvaluatedKey: Record<string, any> | undefined;

      do {
        const scanResult = await client.send(new ScanCommand({
          TableName: tableName,
          ProjectionExpression: 'id',
          ExclusiveStartKey: lastEvaluatedKey ? marshall(lastEvaluatedKey) : undefined,
        }));

        const items = scanResult.Items ?? [];

        // Delete each item
        for (const item of items) {
          try {
            await client.send(new DeleteItemCommand({
              TableName: tableName,
              Key: { id: item.id },
            }));
            deleted++;
          } catch {
            errors++;
          }
        }

        lastEvaluatedKey = scanResult.LastEvaluatedKey ? unmarshall(scanResult.LastEvaluatedKey) : undefined;
      } while (lastEvaluatedKey);
    } catch (error) {
      return { success: false, error: `Failed to clear ${name}: ${error}` };
    }

    results[name] = { deleted, errors };
  }

  return {
    success: true,
    data: {
      message: 'Shopping data cleared',
      results,
    },
  };
}

// ========================================
// ALLOWANCES
// ========================================

/**
 * Lift a household's allowances by hand, with no receipt — friends, testers,
 * the live household. `subscribed || comped` is the entitlement check, so this
 * is also how every allowance gets tested against a real account without buying
 * anything. See MONETIZATION.qmd, "Comping an account".
 */
async function compHousehold(args: Record<string, any>): Promise<McpToolResponse> {
  const { householdId } = args;
  if (!householdId) return { success: false, error: 'Missing required argument: householdId' };
  try {
    const row = await setEntitlement(householdId, 'COMPED');
    return { success: true, data: summarize(row) };
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : String(error) };
  }
}

/** Back to FREE. Counters are left as they are; the caps simply apply again. */
async function uncompHousehold(args: Record<string, any>): Promise<McpToolResponse> {
  const { householdId } = args;
  if (!householdId) return { success: false, error: 'Missing required argument: householdId' };
  try {
    const row = await setEntitlement(householdId, 'FREE');
    return { success: true, data: summarize(row) };
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : String(error) };
  }
}

async function getAllowances(args: Record<string, any>): Promise<McpToolResponse> {
  const { householdId } = args;
  if (!householdId) return { success: false, error: 'Missing required argument: householdId' };
  try {
    const row = await loadAllowance(householdId);
    return { success: true, data: { ...summarize(row), periodStartedAt: row.periodStartedAt } };
  } catch (error) {
    return { success: false, error: error instanceof Error ? error.message : String(error) };
  }
}

// ========================================
// TOOL REGISTRY
// ========================================

type ToolHandler = (args: Record<string, any>) => Promise<McpToolResponse>;

const tools: Record<string, ToolHandler> = {
  list_tables: listTables,
  list_users: listUsers,
  list_households: listHouseholds,
  get_household: getHousehold,
  list_items: listItems,
  get_commits: getCommits,
  delete_item: deleteItem,
  clear_shopping_data: clearShoppingData,
  get_allowances: getAllowances,
  comp_household: compHousehold,
  uncomp_household: uncompHousehold,
};

// ========================================
// HANDLER
// ========================================

export const handler = async (event: McpToolRequest): Promise<McpToolResponse> => {
  console.log('adminMcpFunction invoked:', JSON.stringify(event, null, 2));

  const { tool, args = {} } = event;

  if (!tool) {
    return {
      success: false,
      error: 'Missing required field: tool',
    };
  }

  const toolHandler = tools[tool];

  if (!toolHandler) {
    return {
      success: false,
      error: `Unknown tool: ${tool}. Available tools: ${Object.keys(tools).join(', ')}`,
    };
  }

  try {
    return await toolHandler(args);
  } catch (error) {
    console.error(`Error executing tool ${tool}:`, error);
    return {
      success: false,
      error: `Tool execution failed: ${error}`,
    };
  }
};
