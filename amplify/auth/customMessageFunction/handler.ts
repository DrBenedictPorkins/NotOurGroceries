import { DynamoDBClient, PutItemCommand, ScanCommand } from '@aws-sdk/client-dynamodb';
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb';
import { randomInt } from 'node:crypto';
import { logEvent, logWarning, logFailure } from '../../data/telemetry';

const client = new DynamoDBClient({});

const COMP_CODE_TABLE_NAME = process.env.COMP_CODE_TABLE_NAME!;

/** How many households get comped. The cap is on issuance, not on redemption. */
export const FOUNDER_COMP_LIMIT = 100;

/**
 * Codes get read aloud and typed by hand, so no O, 0, I or 1 — both halves of
 * each confusable pair are out, which is why nothing needs folding on the way
 * back in.
 */
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/**
 * Puts an invite code in the sign-up confirmation email.
 *
 * The code is minted against the address at the moment Cognito sends it, which
 * makes a verified email the thing standing between somebody and a comp. That is
 * the gate the invite page never had: a public endpoint handing out codes is
 * scriptable no matter what is bolted to it, because the code was never the
 * scarce thing — a verified account is.
 *
 * One email, not two. The code arrives beside the confirmation code somebody is
 * already reading, so there is nothing to go and find.
 *
 * A failure here must never stop a sign-up. Cognito sends whatever message this
 * returns, so anything that goes wrong falls back to the ordinary text and the
 * person simply has no code — recoverable by hand, unlike a confirmation email
 * that never arrived.
 */
export const handler = async (event: any) => {
  const trigger: string = event?.triggerSource ?? '';
  const isSignUp = trigger === 'CustomMessage_SignUp'
    || trigger === 'CustomMessage_ResendCode';

  if (!isSignUp) return event;

  const email: string | undefined = event?.request?.userAttributes?.email;
  if (!email) return event;

  try {
    const code = await codeFor(email.toLowerCase().trim());
    if (!code) {
      logEvent('comp.noneLeft', {});
      return event;
    }

    const confirmation = event.request.codeParameter;
    event.response.emailSubject = 'Your Got Dill? confirmation code';
    event.response.emailMessage = [
      `<p>Your confirmation code is <strong>${confirmation}</strong>.</p>`,
      '<p>You are one of the first hundred, so your household is on us — permanently.</p>',
      `<p>Invite code: <strong style="letter-spacing:.15em">${code}</strong></p>`,
      '<p>Once you are in, go to Settings → Plan → Redeem a code.</p>',
    ].join('');
  } catch (error) {
    // Deliberately swallowed. See the note above: no code is a nuisance, no
    // confirmation email is a person who cannot sign up at all.
    logFailure('comp.customMessageFailed', error, {});
  }

  return event;
};

/**
 * This address's code, minted if it does not have one.
 *
 * Keyed by address so a resent confirmation carries the same code rather than
 * burning a second slot — Cognito fires this trigger again on every resend, and
 * somebody who does not receive the first email must not cost us two.
 */
async function codeFor(email: string): Promise<string | null> {
  const existing = await byEmail(email);
  if (existing) return existing.code;

  if (!(await underCap())) return null;

  for (let attempt = 0; attempt < 8; attempt += 1) {
    const code = mint();
    try {
      await client.send(new PutItemCommand({
        TableName: COMP_CODE_TABLE_NAME,
        Item: marshall({
          code,
          issuedToEmail: email,
          issuedAt: new Date().toISOString(),
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          __typename: 'CompCode',
        }),
        ConditionExpression: 'attribute_not_exists(code)',
      }));
      logEvent('comp.issued', {});
      return code;
    } catch (error) {
      // Collision on an eight-character code from a 32-letter alphabet is
      // vanishingly unlikely, but it costs one retry to be certain rather than
      // to overwrite somebody else's code.
      if ((error as { name?: string })?.name === 'ConditionalCheckFailedException') continue;
      throw error;
    }
  }
  logWarning('comp.mintExhausted', {});
  return null;
}

async function byEmail(email: string): Promise<Record<string, any> | null> {
  // A Scan over at most a hundred rows, which is the cap. An index to avoid
  // reading a hundred items would cost more to keep than the read it saves.
  let lastKey: Record<string, any> | undefined;
  do {
    const page = await client.send(new ScanCommand({
      TableName: COMP_CODE_TABLE_NAME,
      FilterExpression: 'issuedToEmail = :e',
      ExpressionAttributeValues: marshall({ ':e': email }),
      ExclusiveStartKey: lastKey,
    }));
    const hit = (page.Items ?? [])[0];
    if (hit) return unmarshall(hit);
    lastKey = page.LastEvaluatedKey;
  } while (lastKey);
  return null;
}

async function underCap(): Promise<boolean> {
  let issued = 0;
  let lastKey: Record<string, any> | undefined;
  do {
    const page = await client.send(new ScanCommand({
      TableName: COMP_CODE_TABLE_NAME,
      ProjectionExpression: 'code',
      Select: 'SPECIFIC_ATTRIBUTES',
      ExclusiveStartKey: lastKey,
    }));
    issued += page.Count ?? 0;
    lastKey = page.LastEvaluatedKey;
  } while (lastKey);
  return issued < FOUNDER_COMP_LIMIT;
}

export function mint(): string {
  let out = '';
  for (let i = 0; i < 8; i += 1) out += ALPHABET[randomInt(ALPHABET.length)];
  return out;
}
