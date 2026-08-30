import { defineBackend } from '@aws-amplify/backend';
import { auth } from './auth/resource';
import {
  data,
  commitStreamHandler,
  searchProductsFunction,
  regenerateInviteCodeFunction,
  joinHouseholdFunction,
  householdMembershipFunction,
  sendInviteEmailFunction,
  aisleExtractionJobHandler,
  inferProductAisleFunction,
  parseIngredientsFunction,
  transcribeAudioFunction,
  adminMcpFunction,
} from './data/resource';
import { storage } from './storage/resource';
import { Function } from 'aws-cdk-lib/aws-lambda';
import { PolicyStatement } from 'aws-cdk-lib/aws-iam';
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
  sendInviteEmailFunction,
  aisleExtractionJobHandler,
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
const sendInviteEmailLambda = backend.sendInviteEmailFunction.resources.lambda as Function;

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
});
householdTable.grantReadData(joinHouseholdLambda);
userTable.grantReadWriteData(joinHouseholdLambda);
// Grant permission to query GSI indexes on Household table
joinHouseholdLambda.addToRolePolicy(new PolicyStatement({
  actions: ['dynamodb:Query'],
  resources: [`${householdTable.tableArn}/index/*`],
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
});
householdTable.grantReadWriteData(householdMembershipLambda);
userTable.grantReadWriteData(householdMembershipLambda);
groceryItemTable.grantReadWriteData(householdMembershipLambda);
commitTable.grantReadWriteData(householdMembershipLambda);
backend.data.resources.tables['HouseholdStore'].grantReadWriteData(householdMembershipLambda);
// The cascade and the member count both go through GSIs.
householdMembershipLambda.addToRolePolicy(new PolicyStatement({
  actions: ['dynamodb:Query'],
  resources: [
    `${userTable.tableArn}/index/*`,
    `${groceryItemTable.tableArn}/index/*`,
    `${commitTable.tableArn}/index/*`,
    `${backend.data.resources.tables['HouseholdStore'].tableArn}/index/*`,
  ],
}));

// Add environment variables and permissions for sendInviteEmailFunction
addEnvVars(sendInviteEmailLambda, {
  HOUSEHOLD_TABLE_NAME: householdTable.tableName,
  USER_TABLE_NAME: userTable.tableName,
  SES_SOURCE_EMAIL: 'noreply@yourdomain.com',  // TODO: Configure this
});
householdTable.grantReadData(sendInviteEmailLambda);
userTable.grantReadData(sendInviteEmailLambda);
// Grant SES permissions
sendInviteEmailLambda.addToRolePolicy(new PolicyStatement({
  actions: ['ses:SendEmail', 'ses:SendRawEmail'],
  resources: ['*'],
}));

// ========================================
// AISLE EXTRACTION JOB HANDLER (Stream-Triggered)
// ========================================

// Get the AisleExtractionJob table
const aisleExtractionJobTable = backend.data.resources.tables['AisleExtractionJob'];

// Get the S3 bucket for aisle images
const aisleImagesBucket = backend.storage.resources.bucket;

// Get the Lambda
const aisleExtractionJobLambda = backend.aisleExtractionJobHandler.resources.lambda as Function;

// Configure DynamoDB Stream trigger
aisleExtractionJobTable.grantStreamRead(aisleExtractionJobLambda);
aisleExtractionJobLambda.addEventSourceMapping('AisleExtractionJobStreamMapping', {
  eventSourceArn: aisleExtractionJobTable.tableStreamArn,
  startingPosition: StartingPosition.LATEST,
  batchSize: 1, // Process one job at a time
  retryAttempts: 0, // We handle retries in the Lambda
});

// Get the HouseholdStore table for updating aisle layout
const householdStoreTableForJob = backend.data.resources.tables['HouseholdStore'];

// Add environment variables
addEnvVars(aisleExtractionJobLambda, {
  JOB_TABLE_NAME: aisleExtractionJobTable.tableName,
  PRODUCT_TABLE_NAME: productTable.tableName,
  MAPPING_TABLE_NAME: backend.data.resources.tables['ProductAisleMapping'].tableName,
  BUCKET_NAME: aisleImagesBucket.bucketName,
  HOUSEHOLD_STORE_TABLE_NAME: householdStoreTableForJob.tableName,
  GROCERY_ITEM_TABLE_NAME: groceryItemTable.tableName,
});

// Grant permissions
aisleExtractionJobTable.grantReadWriteData(aisleExtractionJobLambda);
productTable.grantReadData(aisleExtractionJobLambda);
backend.data.resources.tables['ProductAisleMapping'].grantReadWriteData(aisleExtractionJobLambda);
aisleImagesBucket.grantRead(aisleExtractionJobLambda);
householdStoreTableForJob.grantReadWriteData(aisleExtractionJobLambda);
groceryItemTable.grantReadData(aisleExtractionJobLambda);

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
  AISLE_EXTRACTION_JOB_TABLE: aisleExtractionJobTable.tableName,
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
  aisleExtractionJobTable,
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
