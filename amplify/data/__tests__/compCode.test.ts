import { mint, FOUNDER_COMP_LIMIT } from '../../auth/customMessageFunction/handler';
import { normalize } from '../redeemCompCodeFunction/handler';

/**
 * Invite codes are minted into the sign-up confirmation email and typed back in
 * by hand, so both ends have to agree on what a code looks like. The alphabet
 * excludes O, 0, I and 1 — *both* halves of each confusable pair — which is why
 * nothing needs folding on the way back in: a valid code can never contain one.
 */
describe('invite codes', () => {
  it('never mints a character that can be misread', () => {
    for (let i = 0; i < 500; i += 1) {
      expect(mint()).not.toMatch(/[O0I1]/);
    }
  });

  it('mints eight characters from the agreed alphabet', () => {
    for (let i = 0; i < 100; i += 1) {
      expect(mint()).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{8}$/);
    }
  });

  it('does not mint the same code twice in a short run', () => {
    const seen = new Set<string>();
    for (let i = 0; i < 500; i += 1) seen.add(mint());
    // 32^8 possibilities; a collision in 500 draws would mean the generator is
    // not drawing uniformly.
    expect(seen.size).toBe(500);
  });

  it('caps issuance at a hundred', () => {
    expect(FOUNDER_COMP_LIMIT).toBe(100);
  });
});

/**
 * A code read aloud down a phone or copied out of an email arrives with spaces,
 * dashes and whatever casing the keyboard felt like.
 */
describe('normalize', () => {
  it('accepts a code typed in lower case', () => {
    expect(normalize('abcdefgh')).toBe('ABCDEFGH');
  });

  it('accepts the dashes and spaces people add themselves', () => {
    expect(normalize(' ABCD-EFGH ')).toBe('ABCDEFGH');
    expect(normalize('ABCD EFGH')).toBe('ABCDEFGH');
  });

  it('leaves a clean code untouched', () => {
    expect(normalize('ABCDEFGH')).toBe('ABCDEFGH');
  });

  it('yields an empty string for nothing, so the handler refuses rather than throws', () => {
    expect(normalize('')).toBe('');
    expect(normalize(undefined as unknown as string)).toBe('');
    expect(normalize('!!!')).toBe('');
  });

  it('round-trips anything mint produces', () => {
    for (let i = 0; i < 200; i += 1) {
      const code = mint();
      expect(normalize(code.toLowerCase())).toBe(code);
    }
  });
});
