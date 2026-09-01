import { defineBackend } from '@aws-amplify/backend';
import { auth } from './auth/resource';
import {
  data,
  commitStreamHandler,
  searchProductsFunction,
  regenerateInviteCodeFunction,
  joinHouseholdFunction,
  householdMembershipFunction,
  inferProductAisleFunction,
  parseIngredientsFunction,
  transcribeAudioFunction,
  adminMcpFunction,
} from './data/resource';
import { storage } from './storage/resource';
import { Function } from 'aws-cdk-lib/aws-lambda';
import { PolicyStatement, Role, ServicePrincipal, ManagedPolicy } from 'aws-cdk-lib/aws-iam';
import { StartingPosition } from 'aws-cdk-lib/aws-lambda';

/**
 * @see https://docs.amplify.aws/react/build-a-backend/ to add storage, functions, and more
 */
const backend = defineBackend({
  auth,
  data,
  storage,
  commitStreamHandler,
  searchProductsFunction,
  regenerateInviteCodeFunction,
  joinHouseholdFunction,
  householdMembershipFunction,
  inferProductAisleFunction,
  parseIngredientsFunction,
  transcribeAudioFunction,
  adminMcpFunction,
});

// Password policy: 6 characters, no complexity rules. Cognito's own floor is 6,
// so this is as permissive as AWS allows. Deliberate — this is a 2-user internal
// beta and the default policy (8 + upper + lower + number + symbol) was pure
// friction on a shopping list. Set here because defineAuth doesn't expose it.
backend.auth.resources.cfnResources.cfnUserPool.policies = {
  passwordPolicy: {
    minimumLength: 6,
    requireUppercase: false,
    requireLowercase: false,
    requireNumbers: false,
    requireSymbols: false,
    temporaryPasswordValidityDays: 7,
  },
};

// AppSync request logging.
//
// Off until now, which meant authorization denials were invisible server-side:
// there was no way to answer "did that request get refused, and why" except by
// reproducing it from a client. A claim was made on 2026-08-30 that auth was
// behaving in production, and it had no source behind it — this is that source.
//
// ERROR, not ALL. Errors are the interesting events (denials land here) and ALL
// logs every resolver invocation, which on a shopping list is mostly noise you
// pay to store. `excludeVerboseContent` keeps request and response bodies out of
// CloudWatch — those carry shopping lists and email addresses, and logs are a
// worse place for personal data than the database is.
const appSyncLogRole = new Role(backend.data.stack, 'AppSyncCloudWatchRole', {
  assumedBy: new ServicePrincipal('appsync.amazonaws.com'),
  managedPolicies: [
    ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSAppSyncPushToCloudWatchLogs'),
  ],
});

backend.data.resources.cfnResources.cfnGraphqlApi.logConfig = {
  fieldLogLevel: 'ERROR',
  cloudWatchLogsRoleArn: appSyncLogRole.roleArn,
  excludeVerboseContent: true,
};

// Retention is set outside the stack, deliberately. The log group
// `/aws/appsync/apis/<apiId>` already exists and AppSync owns it, so declaring it
// here fails the deploy with "already exists". It is a one-off, idempotent
// setting:
//
//   aws logs put-retention-policy \
//     --log-group-name /aws/appsync/apis/vdsfrt2plzgwfdae2ucpxtwzh4 \
//     --retention-in-days 14
//
// Set to 14 days on 2026-08-30. Without it the group never expires and quietly
// becomes a running cost.

// Grant Lambda functions access to DynamoDB tables
const groceryItemTable = backend.data.resources.tables['GroceryItem'];
const householdTable = backend.data.resources.tables['Household'];
const commitTable = backend.data.resources.tables['Commit'];
const productTable = backend.data.resources.tables['Product'];
const userTable = backend.data.resources.tables['User'];

// Helper function to add environment variables to a Lambda function
function addEnvVars(lambdaFn: Function, envVars: Record<string, string>) {
  Object.entries(envVars).forEach(([key, value]) => {
    lambdaFn.addEnvironment(key, value);
  });
}

// Get the underlying Lambda Function constructs
const commitStreamLambda = backend.commitStreamHandler.resources.lambda as Function;
const searchProductsLambda = backend.searchProductsFunction.resources.lambda as Function;

// Configure DynamoDB Stream trigger for GroceryItem table
groceryItemTable.grantStreamRead(commitStreamLambda);
commitStreamLambda.addEventSourceMapping('GroceryItemStreamMapping', {
  eventSourceArn: groceryItemTable.tableStreamArn,
  startingPosition: StartingPosition.LATEST,
  batchSize: 10,
  retryAttempts: 3,
});

// Add environment variables and permissions for commitStreamHandler
addEnvVars(commitStreamLambda, {
  HOUSEHOLD_TABLE_NAME: householdTable.tableName,
  COMMIT_TABLE_NAME: commitTable.tableName,
  USER_TABLE_NAME: userTable.tableName,
});
householdTable.grantReadWriteData(commitStreamLambda);
commitTable.grantWriteData(commitStreamLambda);
userTable.grantReadData(commitStreamLambda);

// Add environment variables and permissions for searchProductsFunction
addEnvVars(searchProductsLambda, {
  PRODUCT_TABLE_NAME: productTable.tableName,
});
productTable.grantReadData(searchProductsLambda);

// Get the underlying Lambda Function constructs for new functions
const regenerateInviteCodeLambda = backend.regenerateInviteCodeFunction.resources.lambda as Function;
const joinHouseholdLambda = backend.joinHouseholdFunction.resources.lambda as Function;

// Add environment variables and permissions for regenerateInviteCodeFunction
addEnvVars(regenerateInviteCodeLambda, {
  HOUSEHOLD_TABLE_NAME: householdTable.tableName,
  USER_TABLE_NAME: userTable.tableName,
});
householdTable.grantReadWriteData(regenerateInviteCodeLambda);
userTable.grantReadData(regenerateInviteCodeLambda);

// Add environment variables and permissions for joinHouseholdFunction
addEnvVars(joinHouseholdLambda, {
  HOUSEHOLD_TABLE_NAME: householdTable.tableName,
  USER_TABLE_NAME: userTable.tableName,
  USER_POOL_ID: backend.auth.resources.userPool.userPoolId,
});
// Joining has to grant the Cognito group claim as well as set householdId —
// dynamic group auth is what actually lets the joiner read the household.
joinHouseholdLambda.addToRolePolicy(new PolicyStatement({
  actions: [
    'cognito-idp:CreateGroup',
    'cognito-idp:AdminAddUserToGroup',
    'cognito-idp:AdminRemoveUserFromGroup',
  ],
  resources: [backend.auth.resources.userPool.userPoolArn],
}));
// Write, not just read: joining now spends the invite code, rotating and
// expiring it on the Household row so it admits exactly one person.
householdTable.grantReadWriteData(joinHouseholdLambda);
userTable.grantReadWriteData(joinHouseholdLambda);
// Grant permission to query GSI indexes on both tables. Explicit because these
// tables are imported by ARN, so the grant helpers above do not reach the
// indexes. Household: finding a household by invite code, and checking a
// replacement code is unused. User: reading the colours a household has already
// handed out, so a new member is given a different one.
joinHouseholdLambda.addToRolePolicy(new PolicyStatement({
  actions: ['dynamodb:Query'],
  resources: [`${householdTable.tableArn}/index/*`, `${userTable.tableArn}/index/*`],
}));

// Membership changes: remove a member, or leave (and delete the household when
// the last member goes). Needs write on User because `allow.owner()` prevents
// any client doing it, and write on the household-scoped tables for the cascade.
const householdMembershipLambda = backend.householdMembershipFunction.resources.lambda as Function;
addEnvVars(householdMembershipLambda, {
  HOUSEHOLD_TABLE_NAME: householdTable.tableName,
  USER_TABLE_NAME: userTable.tableName,
  GROCERY_ITEM_TABLE_NAME: groceryItemTable.tableName,
  COMMIT_TABLE_NAME: commitTable.tableName,
  HOUSEHOLD_STORE_TABLE_NAME: backend.data.resources.tables['HouseholdStore'].tableName,
  USER_POOL_ID: backend.auth.resources.userPool.userPoolId,
});
// Creating a household creates its group; removing or leaving revokes the claim,
// and emptying one deletes the group outright. Without the revoke, somebody
// removed from a household keeps read access until their token expires.
householdMembershipLambda.addToRolePolicy(new PolicyStatement({
  actions: [
    'cognito-idp:CreateGroup',
    'cognito-idp:DeleteGroup',
    'cognito-idp:AdminAddUserToGroup',
    'cognito-idp:AdminRemoveUserFromGroup',
    // Deleting the sign-in itself, for the deleteAccount action. App Store
    // guideline 5.1.1(v) requires an app that creates accounts to let people
    // delete them from inside the app.
    'cognito-idp:AdminDeleteUser',
  ],
  resources: [backend.auth.resources.userPool.userPoolArn],
}));
householdTable.grantReadWriteData(householdMembershipLambda);
userTable.grantReadWriteData(householdMembershipLambda);
groceryItemTable.grantReadWriteData(householdMembershipLambda);
commitTable.grantReadWriteData(householdMembershipLambda);
backend.data.resources.tables['HouseholdStore'].grantReadWriteData(householdMembershipLambda);
// The cascade and the member count both go through GSIs.
householdMembershipLambda.addToRolePolicy(new PolicyStatement({
  actions: ['dynamodb:Query'],
  resources: [
    `${householdTable.tableArn}/index/*`,
    `${userTable.tableArn}/index/*`,
    `${groceryItemTable.tableArn}/index/*`,
    `${commitTable.tableArn}/index/*`,
    `${backend.data.resources.tables['HouseholdStore'].tableArn}/index/*`,
  ],
}));

// ========================================
// INFER PRODUCT AISLE FUNCTION
// ========================================

const productAisleMappingTable = backend.data.resources.tables['ProductAisleMapping'];
const inferProductAisleLambda = backend.inferProductAisleFunction.resources.lambda as Function;

// Add environment variables
addEnvVars(inferProductAisleLambda, {
  MAPPING_TABLE_NAME: productAisleMappingTable.tableName,
  // The store's own aisle layout. Inference used to build its context purely
  // from products already mapped, so a store nobody had mapped yet could never
  // bootstrap — it demanded a directory scan even when it had a perfectly good
  // list of departments sitting on it.
  HOUSEHOLD_STORE_TABLE_NAME: backend.data.resources.tables['HouseholdStore'].tableName,
});

// Grant read access to ProductAisleMapping table
productAisleMappingTable.grantReadData(inferProductAisleLambda);
backend.data.resources.tables['HouseholdStore'].grantReadData(inferProductAisleLambda);

// Grant permission to query the GSI (byStoreId index)
inferProductAisleLambda.addToRolePolicy(new PolicyStatement({
  actions: ['dynamodb:Query'],
  resources: [`${productAisleMappingTable.tableArn}/index/*`],
}));

// ========================================
// ADMIN MCP FUNCTION (Database Management)
// ========================================

// Get references to all tables
const storeTable = backend.data.resources.tables['Store'];
const aisleTable = backend.data.resources.tables['Aisle'];
const householdStoreTable = backend.data.resources.tables['HouseholdStore'];
const shoppingRequestTable = backend.data.resources.tables['ShoppingRequest'];

// Get the Lambda
const adminMcpLambda = backend.adminMcpFunction.resources.lambda as Function;

// Add environment variables for all tables
addEnvVars(adminMcpLambda, {
  USER_TABLE: userTable.tableName,
  HOUSEHOLD_TABLE: householdTable.tableName,
  GROCERY_ITEM_TABLE: groceryItemTable.tableName,
  PRODUCT_TABLE: productTable.tableName,
  STORE_TABLE: storeTable.tableName,
  AISLE_TABLE: aisleTable.tableName,
  HOUSEHOLD_STORE_TABLE: householdStoreTable.tableName,
  PRODUCT_AISLE_MAPPING_TABLE: productAisleMappingTable.tableName,
  COMMIT_TABLE: commitTable.tableName,
  SHOPPING_REQUEST_TABLE: shoppingRequestTable.tableName,
});

// Grant DynamoDB permissions to all tables
const allTables = [
  userTable,
  householdTable,
  groceryItemTable,
  productTable,
  storeTable,
  aisleTable,
  householdStoreTable,
  productAisleMappingTable,
  commitTable,
  shoppingRequestTable,
];

// Grant read/write access to all tables
allTables.forEach(table => {
  table.grantReadWriteData(adminMcpLambda);
});

// Grant additional permissions for scan, query, describe, and batch operations
adminMcpLambda.addToRolePolicy(new PolicyStatement({
  actions: [
    'dynamodb:Scan',
    'dynamodb:Query',
    'dynamodb:GetItem',
    'dynamodb:DeleteItem',
    'dynamodb:DescribeTable',
    'dynamodb:BatchWriteItem',
  ],
  resources: allTables.map(table => table.tableArn),
}));

// Grant permission to query GSI indexes on all tables
adminMcpLambda.addToRolePolicy(new PolicyStatement({
  actions: ['dynamodb:Query', 'dynamodb:Scan'],
  resources: allTables.map(table => `${table.tableArn}/index/*`),
}));
