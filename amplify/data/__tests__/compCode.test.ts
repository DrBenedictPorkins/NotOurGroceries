import { codeFor } from '../../auth/customMessageFunction/handler';
import { normalize, FOUNDER_COMP_LIMIT } from '../redeemCompCodeFunction/handler';

const SECRET = 'test-secret';

/**
 * The invite code is an HMAC of the address it was mailed to, recomputed at
 * redemption from the caller's own token. That shape was forced by a
 * CloudFormation cycle — an auth trigger cannot be granted a data-stack table —
 * and turned out to be the better design: no list of codes exists to steal, and
 * a code that leaks is worth nothing to whoever finds it because they cannot
 * sign in as the address it belongs to.
 */
describe('codeFor', () => {
  it('gives the same address the same code every time, so a resent email matches', () => {
    expect(codeFor('sam@example.com', SECRET)).toBe(codeFor('sam@example.com', SECRET));
  });

  it('ignores casing and surrounding space, because people retype their address', () => {
    const canonical = codeFor('sam@example.com', SECRET);
    expect(codeFor('SAM@example.com', SECRET)).toBe(canonical);
    expect(codeFor('  sam@example.com  ', SECRET)).toBe(canonical);
  });

  it('gives different addresses different codes', () => {
    expect(codeFor('sam@example.com', SECRET)).not.toBe(codeFor('alex@example.com', SECRET));
  });

  it('changes completely if the secret changes, so a leaked code dies with a rotation', () => {
    expect(codeFor('sam@example.com', SECRET)).not.toBe(codeFor('sam@example.com', 'other'));
  });

  it('never emits a character that can be misread', () => {
    for (let i = 0; i < 500; i += 1) {
      expect(codeFor(`user${i}@example.com`, SECRET)).not.toMatch(/[O0I1]/);
    }
  });

  it('is eight characters from the agreed alphabet', () => {
    for (let i = 0; i < 200; i += 1) {
      expect(codeFor(`user${i}@example.com`, SECRET))
        .toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/);
    }
  });

  it('spreads across the alphabet rather than collapsing onto a few letters', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 400; i += 1) seen.add(codeFor(`user${i}@example.com`, SECRET));
    // Collisions here would mean the derivation is not using the digest evenly.
    expect(seen.size).toBeGreaterThan(395);
  });
});

/**
 * A code copied out of an email arrives with whatever spacing and casing the
 * keyboard felt like.
 */
describe('normalize', () => {
  it('accepts lower case', () => {
    expect(normalize('abcdefgh')).toBe('ABCDEFGH');
  });

  it('accepts the dashes and spaces people add themselves', () => {
    expect(normalize(' ABCD-EFGH ')).toBe('ABCDEFGH');
    expect(normalize('ABCD EFGH')).toBe('ABCDEFGH');
  });

  it('yields an empty string for nothing, so the handler refuses rather than throws', () => {
    expect(normalize('')).toBe('');
    expect(normalize(undefined as unknown as string)).toBe('');
    expect(normalize('!!!')).toBe('');
  });

  it('round-trips anything codeFor produces', () => {
    for (let i = 0; i < 100; i += 1) {
      const code = codeFor(`user${i}@example.com`, SECRET);
      expect(normalize(code.toLowerCase())).toBe(code);
    }
  });
});

describe('the founder cap', () => {
  it('is a hundred', () => {
    expect(FOUNDER_COMP_LIMIT).toBe(100);
  });
});
