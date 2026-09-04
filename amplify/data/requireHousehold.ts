import { logWarning } from './telemetry';

/**
 * A household is the unit this app operates on. Everything a person can do —
 * a list, a store, a parse, a transcription — happens inside one.
 *
 * The client already enforces that: `HouseholdSetupView` will not let you past
 * onboarding until you create or join. But that is a screen, not a rule. A token
 * is all anyone needs to call these mutations directly, and until this existed
 * every custom mutation was `allow.authenticated()` with no membership check.
 *
 * The model tables were never exposed — `groupDefinedIn` means no household, no
 * rows. The gap was the custom Lambdas, and the expensive ones at that: an
 * account created seconds ago through open signup could call Claude and OpenAI on
 * our keys, unmetered, forever. It could see nothing; it could spend plenty.
 *
 * So: no household, no household group, no call.
 *
 * `joinHousehold` and `manageHouseholdMembership` are deliberately exempt. They
 * are how a person gets a household in the first place, and guarding them would
 * lock everyone out of the app permanently.
 */

/** The shape AppSync hands a Lambda resolver for a Cognito-authenticated call. */
type IdentityBearing = {
  identity?: {
    sub?: string;
    claims?: Record<string, unknown>;
    groups?: string[] | null;
  };
};

/**
 * Household ids the caller belongs to, from the token.
 *
 * `cognito:groups` arrives as an array on the claims, and AppSync also surfaces
 * it as `identity.groups`. Both are read because which one is populated depends
 * on the resolver type, and a guard that silently sees no groups would lock out
 * every legitimate user rather than fail loudly.
 */
export function callerHouseholdIds(event: unknown): string[] {
  const identity = (event as IdentityBearing).identity;
  if (!identity) return [];

  const fromClaims = identity.claims?.['cognito:groups'];
  const raw = identity.groups ?? fromClaims;

  if (Array.isArray(raw)) {
    return raw.filter((g): g is string => typeof g === 'string' && g.length > 0);
  }
  // Some paths deliver it as a comma-separated string.
  if (typeof raw === 'string' && raw.trim()) {
    return raw.split(',').map((g) => g.trim()).filter(Boolean);
  }
  return [];
}

/**
 * Throw unless the caller is in a household.
 *
 * The message is deliberately plain: this is not a state a real user of the app
 * can reach, because onboarding will not let them. Anyone seeing it either
 * bypassed the client or is holding a token from before they left a household.
 */
export function requireHousehold(event: unknown): string[] {
  const households = callerHouseholdIds(event);
  if (households.length === 0) {
    logWarning('auth.rejected', { reason: 'no_household' });
    throw new Error('You need to create or join a household first.');
  }
  return households;
}
