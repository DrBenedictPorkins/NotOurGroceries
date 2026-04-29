import { util } from '@aws-appsync/utils';

export function request(ctx) {
  const { id, storeId, normalizedName, productId, aisleId, confidence, source, reasoning, mappedAt } = ctx.args;

  const now = util.time.nowISO8601();

  const expNames = {
    '#typename': '__typename',
    '#storeId': 'storeId',
    '#aisleId': 'aisleId',
    '#createdAt': 'createdAt',
    '#updatedAt': 'updatedAt',
  };

  const expValues = {
    ':typename': util.dynamodb.toDynamoDB('ProductAisleMapping'),
    ':storeId': util.dynamodb.toDynamoDB(storeId),
    ':aisleId': util.dynamodb.toDynamoDB(aisleId),
    ':now': util.dynamodb.toDynamoDB(now),
  };

  const sets = [
    '#typename = :typename',
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
