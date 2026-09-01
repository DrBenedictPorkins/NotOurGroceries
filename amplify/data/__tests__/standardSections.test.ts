import * as fs from 'fs';
import * as path from 'path';

/**
 * The seven departments are a closed set.
 *
 * A department is a *place*: it has a sign hanging over it and you walk to it.
 * Every supermarket has these seven and no supermarket has an eighth. There is no
 * Baby department, no Snacks department, no Dried Fruit department — those are
 * facts about a product, and they live in a numbered aisle that only the shopper
 * can tell us about.
 *
 * Eleven such categories were once in this list. They were added to give aisle
 * inference somewhere to put brown sugar, and the result was a brand-new store
 * arriving with dozens of sections nobody could walk to.
 *
 * This test exists so that cannot happen twice. Adding to the list fails here,
 * loudly, with this comment attached. If a genuine new department is ever needed
 * — one with a sign, present in essentially every shop — it takes a deliberate
 * edit to this file, and the matching lock in `AisleNamingTests.swift`.
 */
const DEPARTMENTS = [
  'standard-produce',
  'standard-bakery',
  'standard-deli',
  'standard-seafood',
  'standard-meat',
  'standard-dairy',
  'standard-frozen',
] as const;

/** Categories that have been wrongly modelled as departments before. */
const NOT_DEPARTMENTS = [
  'standard-pantry',
  'standard-canned',
  'standard-condiments',
  'standard-baking',
  'standard-snacks',
  'standard-beverages',
  'standard-personal',
  'standard-pharmacy',
  'standard-baby',
  'standard-pet',
  'standard-household',
];

function idsDeclaredIn(file: string): string[] {
  const source = fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
  return [...source.matchAll(/'(standard-[a-z]+)'/g)].map((m) => m[1]);
}

describe('standard sections are a closed set', () => {
  it('the inference handler declares exactly the seven departments', () => {
    const declared = idsDeclaredIn('inferProductAisleFunction/handler.ts');
    expect([...new Set(declared)].sort()).toEqual([...DEPARTMENTS].sort());
  });

  it.each(NOT_DEPARTMENTS)('%s is a product category, not a place', (category) => {
    expect(idsDeclaredIn('inferProductAisleFunction/handler.ts')).not.toContain(category);
  });

  it('has seven, because a supermarket has seven', () => {
    expect(DEPARTMENTS).toHaveLength(7);
  });
});
