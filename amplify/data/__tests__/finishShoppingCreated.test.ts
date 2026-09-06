import { parseCreated } from '../finishShoppingFunction/handler';

/**
 * `created` carries the items added while offline mid-trip — rows the server has
 * never seen. It arrives as AWSJSON, which means a *string*, and it is the only
 * part of the finish call whose shape is not checked by GraphQL.
 *
 * Which makes it the one input that could throw and take the rest of the finish
 * down with it. The whole point of this call is that ending a trip is a single
 * all-or-nothing statement; one malformed entry must cost that entry and nothing
 * else. So every bad shape here has to come back as a list, never as an
 * exception, and valid siblings have to survive alongside the bad one.
 */
describe('parseCreated', () => {
  it('parses the JSON string AppSync actually delivers', () => {
    const wire = JSON.stringify([{ id: 'i1', name: 'milk' }, { id: 'i2', name: 'eggs' }]);
    expect(parseCreated(wire)).toEqual([
      { id: 'i1', name: 'milk' },
      { id: 'i2', name: 'eggs' },
    ]);
  });

  it('accepts an array that has already been parsed', () => {
    const items = [{ id: 'i1', name: 'milk' }];
    expect(parseCreated(items)).toEqual([{ id: 'i1', name: 'milk' }]);
  });

  it('keeps the full item, not just the fields this function knows about', () => {
    // The payload is a whole GroceryItem; nothing here may narrow it.
    const wire = JSON.stringify([
      { id: 'i1', name: 'milk', householdId: 'h1', status: 'IN_CART', notes: 'the small one' },
    ]);
    expect(parseCreated(wire)[0]).toEqual({
      id: 'i1',
      name: 'milk',
      householdId: 'h1',
      status: 'IN_CART',
      notes: 'the small one',
    });
  });

  it('returns nothing for a string that is not JSON, rather than throwing', () => {
    const warn = jest.spyOn(console, 'warn').mockImplementation(() => {});
    expect(() => parseCreated('{not json')).not.toThrow();
    expect(parseCreated('{not json')).toEqual([]);
    warn.mockRestore();
  });

  it('returns nothing for valid JSON that is not an array', () => {
    expect(parseCreated(JSON.stringify({ id: 'i1' }))).toEqual([]);
    expect(parseCreated({ id: 'i1' })).toEqual([]);
    expect(parseCreated(JSON.stringify('milk'))).toEqual([]);
    expect(parseCreated(42)).toEqual([]);
  });

  it('drops an entry with no id and keeps the ones around it', () => {
    // The failure this exists to prevent: one bad row losing a finished trip.
    const wire = JSON.stringify([
      { id: 'i1', name: 'milk' },
      { name: 'eggs' },
      { id: 'i3', name: 'bread' },
    ]);
    expect(parseCreated(wire).map((i) => i.id)).toEqual(['i1', 'i3']);
  });

  it('drops an entry whose id is not a string', () => {
    const wire = JSON.stringify([{ id: 7, name: 'milk' }, { id: null }, { id: 'i3' }]);
    expect(parseCreated(wire).map((i) => i.id)).toEqual(['i3']);
  });

  it('drops nulls and primitives sitting in the array', () => {
    const wire = JSON.stringify([null, 'milk', 3, { id: 'i1' }]);
    expect(parseCreated(wire)).toEqual([{ id: 'i1' }]);
  });

  it('returns nothing when there is nothing to create', () => {
    expect(parseCreated(null)).toEqual([]);
    expect(parseCreated(undefined)).toEqual([]);
    expect(parseCreated('')).toEqual([]);
    expect(parseCreated('[]')).toEqual([]);
    expect(parseCreated([])).toEqual([]);
  });
});
