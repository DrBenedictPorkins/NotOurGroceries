import { stripHallucinatedTail } from '../transcribeAudioFunction/handler';

/**
 * Whisper was trained largely on YouTube captions, so a recording that ends in
 * silence gets completed with caption boilerplate. Reported from a real shop as
 * "Thank you for watching" appearing at the end of a dictated shopping list.
 *
 * The risk in stripping it is the opposite mistake — eating a real word — so
 * these tests care as much about what survives as about what goes.
 */
describe('stripHallucinatedTail', () => {
  it('removes the reported phrase', () => {
    expect(stripHallucinatedTail('milk, eggs, bread. Thank you for watching'))
      .toBe('milk, eggs, bread');
  });

  it('removes it with punctuation and mixed case', () => {
    expect(stripHallucinatedTail('milk and eggs. Thanks for watching!'))
      .toBe('milk and eggs');
  });

  it('removes two stacked on top of each other', () => {
    expect(stripHallucinatedTail('bananas. Thank you for watching. Please subscribe'))
      .toBe('bananas');
  });

  it('leaves a transcript that has none alone', () => {
    expect(stripHallucinatedTail('milk, eggs, bread')).toBe('milk, eggs, bread');
  });

  it('keeps a real word that merely ends with a listed phrase', () => {
    // "goodbye" ends with "bye", and somebody could plausibly be buying
    // something whose name does. Only whole sentences are stripped.
    expect(stripHallucinatedTail('goodbye')).toBe('goodbye');
  });

  it('keeps thanks said mid-list', () => {
    expect(stripHallucinatedTail('thank you for the list, now get milk'))
      .toBe('thank you for the list, now get milk');
  });

  it('does not strip a phrase that is part of an item', () => {
    expect(stripHallucinatedTail('bye bye baby wipes')).toBe('bye bye baby wipes');
  });

  it('handles an empty transcript', () => {
    expect(stripHallucinatedTail('')).toBe('');
    expect(stripHallucinatedTail('   ')).toBe('');
  });

  it('handles a transcript that is nothing but boilerplate', () => {
    // Silence recorded by accident. Better to return nothing than a fake item.
    expect(stripHallucinatedTail('Thank you for watching')).toBe('');
  });

  it('strips across a newline', () => {
    expect(stripHallucinatedTail('milk\neggs\nThanks for watching')).toBe('milk\neggs');
  });
});
