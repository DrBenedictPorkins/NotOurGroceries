import { normalize } from '../redeemCompCodeFunction/handler';

/**
 * Comp codes travel by voice and by hand — read off a message, typed into the
 * app with a thumb. Every code that fails to normalize costs one of the hundred
 * slots a support conversation, because "that code isn't one of ours" is
 * indistinguishable from a real invalid code.
 *
 * So the tests are about the ways people write down something they were told:
 * lower case, dashes for readability, a stray space, a full stop at the end.
 * The one thing that must never happen is a *valid* code being changed into a
 * different string.
 */
describe('normalize', () => {
  it('upper-cases a code somebody typed in lower case', () => {
    expect(normalize('h7kq4m')).toBe('H7KQ4M');
  });

  it('leaves a correctly typed code exactly as it is', () => {
    expect(normalize('H7KQ4M')).toBe('H7KQ4M');
  });

  it('strips the dashes people add to group the characters', () => {
    expect(normalize('H7K-Q4M')).toBe('H7KQ4M');
    expect(normalize('h7k-q4m-xyz')).toBe('H7KQ4MXYZ');
  });

  it('strips spaces, including the ones autocorrect leaves behind', () => {
    expect(normalize('H7K Q4M')).toBe('H7KQ4M');
    expect(normalize('  H7KQ4M  ')).toBe('H7KQ4M');
  });

  it('strips the other punctuation a keyboard offers up', () => {
    expect(normalize('H7KQ4M.')).toBe('H7KQ4M');
    expect(normalize('“H7KQ4M”')).toBe('H7KQ4M');
    expect(normalize('H7K_Q4M')).toBe('H7KQ4M');
  });

  it('handles a code dictated with everything at once', () => {
    expect(normalize('  h7k - q4m. ')).toBe('H7KQ4M');
  });

  it('returns an empty string for an empty entry', () => {
    expect(normalize('')).toBe('');
    expect(normalize('   ')).toBe('');
  });

  it('returns an empty string when the argument is missing', () => {
    // The mutation argument is optional at the wire level, and the handler
    // treats "" as INVALID rather than looking it up.
    expect(normalize(undefined as unknown as string)).toBe('');
    expect(normalize(null as unknown as string)).toBe('');
  });

  it('returns an empty string for an entry that is nothing but punctuation', () => {
    expect(normalize('---')).toBe('');
  });
});
