import { logEvent, logWarning, logFailure } from '../telemetry';
import { DynamoDBClient, GetItemCommand, UpdateItemCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import {
  CognitoIdentityProviderClient,
  AdminUserGlobalSignOutCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import type { Schema } from '../resource';

const client = new DynamoDBClient({});
const cognito = new CognitoIdentityProviderClient({});

const USER_TABLE_NAME = process.env.USER_TABLE_NAME!;
const USER_POOL_ID = process.env.USER_POOL_ID!;

type Handler = Schema['claimDevice']['functionHandler'];

/**
 * One account, one device.
 *
 * `activeShopperId` holds a user id, not a device, so the same account signed in
 * twice makes both phones believe they are the shopper: both get the editable At
 * Store screen, neither drops into observer mode, take-over is a no-op against
 * yourself, and finishing on both produces two trips with different client-side
 * `tripId`s that the idempotency guard cannot recognise as the same trip. Two
 * people on one account behave worse than two people on two accounts, which is
 * the opposite of what a shared household is supposed to do.
 *
 * Rather than teach every one of those places about devices, the account only
 * ever has one. Newest sign-in wins, because the ordinary reason for a second
 * device is that the first one has been replaced.
 *
 * Two actions:
 *   claim  — sign-in. Records this device and globally signs out the others.
 *   verify — launch and foreground. Says whether this device still holds the
 *            account, so a superseded one can stand down on its own.
 */
export const handler: Handler = async (event) => {
  const identity = (event as { identity?: { sub?: string; username?: string } }).identity;
  const userId = identity?.sub;
  if (!userId) {
    logWarning('device.rejected', { reason: 'no_identity' });
    throw new Error('Not signed in.');
  }

  const { action, deviceId, deviceName } = event.arguments;
  // Empty is not merely useless, it is load-bearing in the wrong direction:
  // `deviceState` reads a blank registration as "cannot tell" and holds the
  // account, so a claim that wrote one would make the account permanently
  // un-evictable. Refuse it at the door.
  if (!deviceId || !deviceId.trim()) throw new Error('No device id.');

  const existing = await readUser(userId);
  const heldBy: string | undefined = existing?.activeDeviceId;

  if (action === 'verify') {
    // No registration at all means an account that has not claimed since this
    // shipped. Treat it as held rather than evicting everybody on upgrade.
    const stillOurs = !heldBy || heldBy === deviceId;
    return {
      stillOurs,
      activeDeviceName: stillOurs ? null : (existing?.activeDeviceName ?? null),
    };
  }

  if (action !== 'claim') throw new Error(`Unknown action: ${action}`);

  const now = new Date().toISOString();
  await client.send(new UpdateItemCommand({
    TableName: USER_TABLE_NAME,
    Key: marshall({ id: userId }),
    UpdateExpression:
      'SET activeDeviceId = :d, activeDeviceName = :n, activeDeviceClaimedAt = :now, updatedAt = :now',
    ExpressionAttributeValues: marshall({
      ':d': deviceId,
      ':n': deviceName ?? 'a phone',
      ':now': now,
    }),
  }));

  // Kills every refresh token this account holds, including the one that was
  // just issued — Cognito reissues on the next call from this device, so the
  // claimer survives and the others cannot renew. Their access tokens stay valid
  // until they expire, which is why the client also verifies on every launch and
  // foreground rather than waiting for Cognito to notice.
  //
  // Best effort: a failure here leaves an old device running for up to an hour,
  // which the verify path then catches. Failing the sign-in over it would be
  // worse than the thing it prevents.
  if (heldBy && heldBy !== deviceId) {
    try {
      await cognito.send(new AdminUserGlobalSignOutCommand({
        UserPoolId: USER_POOL_ID,
        Username: userId,
      }));
      logEvent('device.evictedOthers', { userId });
    } catch (error) {
      logFailure('device.globalSignOutFailed', error, { userId });
    }
  }

  logEvent('device.claimed', { userId, replaced: Boolean(heldBy && heldBy !== deviceId) });
  return { stillOurs: true, activeDeviceName: null };
};

async function readUser(userId: string): Promise<Record<string, any> | null> {
  const result = await client.send(new GetItemCommand({
    TableName: USER_TABLE_NAME,
    Key: marshall({ id: userId }),
  }));
  return result.Item ? unmarshall(result.Item) : null;
}
