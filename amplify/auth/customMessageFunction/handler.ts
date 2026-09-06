import { createHmac } from 'node:crypto';

/**
 * Codes get read aloud and typed by hand, so no O, 0, I or 1 — both halves of
 * each confusable pair are out, which is why nothing needs folding on the way
 * back in.
 */
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/**
 * Puts an invite code in the sign-up confirmation email.
 *
 * The code is **derived from the address**, not drawn from a table. That is not
 * a cleverness for its own sake: this function is an auth trigger and therefore
 * lives in the auth stack, while the code table lives in the data stack, which
 * already depends on auth for group authorisation. Granting it the table made
 * those two stacks depend on each other and CloudFormation refused the whole
 * deployment — the nested-stack cycle that has bitten this project before.
 *
 * Deriving instead means the trigger touches nothing. No table, no grant, no
 * cycle, and nothing to fail while somebody is trying to sign up.
 *
 * It is also a better code. Because it is a function of the address, it can only
 * be redeemed by the account it was mailed to — a code that leaks is worth
 * nothing to whoever finds it, which is the property the public invite page
 * could never have. `redeemCompCode` recomputes it from the caller's own token
 * and compares, so the secret never leaves the server and no list of codes
 * exists to be stolen.
 */
export const handler = async (event: any) => {
  const trigger: string = event?.triggerSource ?? '';
  if (trigger !== 'CustomMessage_SignUp' && trigger !== 'CustomMessage_ResendCode') {
    return event;
  }

  const email: string | undefined = event?.request?.userAttributes?.email;
  if (!email) return event;

  try {
    const code = codeFor(email);
    const confirmation = event.request.codeParameter;
    event.response.emailSubject = 'Your Got Dill? confirmation code';
    event.response.emailMessage = [
      `<p>Your confirmation code is <strong>${confirmation}</strong>.</p>`,
      '<p>You are one of the first hundred, so your household is on us — permanently.</p>',
      `<p>Invite code: <strong style="letter-spacing:.15em">${code}</strong></p>`,
      '<p>Once you are in: Settings → Plan → Redeem a code.</p>',
    ].join('');
  } catch (error) {
    // Deliberately swallowed. Cognito sends whatever this returns, so a throw
    // here is a confirmation email that never arrives — somebody who cannot sign
    // up at all. No code is a nuisance; no email is a wall.
    console.error(JSON.stringify({ event: 'comp.customMessageFailed' }));
  }

  return event;
};

/**
 * The code for an address. Stable, so a resent confirmation carries the same one
 * rather than a second.
 */
export function codeFor(email: string, secret = process.env.COMP_CODE_SECRET ?? ''): string {
  const normalized = email.trim().toLowerCase();
  const digest = createHmac('sha256', secret).update(normalized).digest();
  let out = '';
  for (let i = 0; i < 8; i += 1) {
    out += ALPHABET[digest[i] % ALPHABET.length];
  }
  return out;
}
