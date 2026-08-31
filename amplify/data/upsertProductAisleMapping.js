import { util } from '@aws-appsync/utils';

export function request(ctx) {
  const { id, householdId, storeId, normalizedName, productId, aisleId, confidence, source, reasoning, mappedAt, userAisleOverride } = ctx.args;

  // This resolver writes to the mapping table directly, so the model's
  // `groupDefinedIn('householdId')` rule never runs for it — the check has to
  // happen here or the mutation is a way around the whole scheme. It also has
  // to WRITE householdId, or every row it creates comes back denied on read
  // because the field the rule inspects is missing.
  const groups = ctx.identity && ctx.identity.groups ? ctx.identity.groups : [];
  if (groups.indexOf(householdId) === -1) {
    util.unauthorized();
  }

  const now = util.time.nowISO8601();

  const expNames = {
    '#typename': '__typename',
    '#householdId': 'householdId',
    '#storeId': 'storeId',
    '#aisleId': 'aisleId',
    '#createdAt': 'createdAt',
    '#updatedAt': 'updatedAt',
  };

  const expValues = {
    ':typename': util.dynamodb.toDynamoDB('ProductAisleMapping'),
    ':householdId': util.dynamodb.toDynamoDB(householdId),
    ':storeId': util.dynamodb.toDynamoDB(storeId),
    ':aisleId': util.dynamodb.toDynamoDB(aisleId),
    ':now': util.dynamodb.toDynamoDB(now),
  };

  const sets = [
    '#typename = :typename',
    '#householdId = :householdId',
    '#storeId = :storeId',
    '#aisleId = :aisleId',
    '#createdAt = if_not_exists(#createdAt, :now)',
    '#updatedAt = :now',
  ];

  if (normalizedName != null) {
    expNames['#normalizedName'] = 'normalizedName';
    expValues[':normalizedName'] = util.dynamodb.toDynamoDB(normalizedName);
    sets.push('#normalizedName = :normalizedName');
  }
  if (productId != null) {
    expNames['#productId'] = 'productId';
    expValues[':productId'] = util.dynamodb.toDynamoDB(productId);
    sets.push('#productId = :productId');
  }
  if (confidence != null) {
    expNames['#confidence'] = 'confidence';
    expValues[':confidence'] = util.dynamodb.toDynamoDB(confidence);
    sets.push('#confidence = :confidence');
  }
  if (source != null) {
    expNames['#source'] = 'source';
    expValues[':source'] = util.dynamodb.toDynamoDB(source);
    sets.push('#source = :source');
  }
  if (reasoning != null) {
    expNames['#reasoning'] = 'reasoning';
    expValues[':reasoning'] = util.dynamodb.toDynamoDB(reasoning);
    sets.push('#reasoning = :reasoning');
  }
  if (mappedAt != null) {
    expNames['#mappedAt'] = 'mappedAt';
    expValues[':mappedAt'] = util.dynamodb.toDynamoDB(mappedAt);
    sets.push('#mappedAt = :mappedAt');
  }
  // A person's own sighting. Written on its own attribute rather than into
  // `aisleId` so the model's guess stays visible next to it and, more to the
  // point, so the next inference run overwriting `aisleId` cannot quietly undo
  // what somebody saw with their own eyes.
  if (userAisleOverride != null) {
    expNames['#userAisleOverride'] = 'userAisleOverride';
    expValues[':userAisleOverride'] = util.dynamodb.toDynamoDB(userAisleOverride);
    sets.push('#userAisleOverride = :userAisleOverride');
  }

  return {
    operation: 'UpdateItem',
    key: util.dynamodb.toMapValues({ id }),
    update: {
      expression: 'SET ' + sets.join(', '),
      expressionNames: expNames,
      expressionValues: expValues,
    },
  };
}

export function response(ctx) {
  if (ctx.error) {
    util.error(ctx.error.message, ctx.error.type);
  }
  return ctx.result;
}
