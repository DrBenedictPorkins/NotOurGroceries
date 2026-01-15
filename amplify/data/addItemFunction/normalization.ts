/**
 * Normalize item name for deduplication
 * - Lowercase and trim
 * - Remove articles (a, an, the)
 * - Handle common plurals
 */
export function normalizeName(name: string): string {
  let normalized = name.toLowerCase().trim();

  // Remove leading articles
  normalized = normalized.replace(/^(a |an |the )/i, '');

  // Exception list for words that naturally end in 's' or shouldn't be singularized
  const exceptions = ['hummus', 'asparagus', 'couscous', 'citrus', 'cheese', 'rice', 'clothes'];

  // Handle common plural patterns (only if not in exception list)
  // -ies → -y (berries → berry, strawberries → strawberry)
  if (normalized.endsWith('ies') && normalized.length > 4) {
    normalized = normalized.slice(0, -3) + 'y';
  }
  // -oes → -o (potatoes → potato, tomatoes → tomato)
  else if (normalized.endsWith('oes') && normalized.length > 4) {
    normalized = normalized.slice(0, -2);
  }
  // -ves → -f (loaves → loaf)
  else if (normalized.endsWith('ves') && normalized.length > 4) {
    normalized = normalized.slice(0, -3) + 'f';
  }
  // -sses, -shes, -ches, -xes, -zes → remove -es (dishes → dish, boxes → box)
  // But not cheese, rice, clothes, etc.
  else if (normalized.endsWith('es') && normalized.length > 3 &&
           !exceptions.includes(normalized)) {
    const stem = normalized.slice(0, -2);
    // Only remove -es if the stem ends in s, sh, ch, x, or z
    if (stem.endsWith('s') || stem.endsWith('sh') || stem.endsWith('ch') ||
        stem.endsWith('x') || stem.endsWith('z')) {
      normalized = stem;
    }
    // Otherwise, just remove the final -s (apples → apple)
    else {
      normalized = normalized.slice(0, -1);
    }
  }
  // -s → (carrots → carrot) but not words that end naturally in s
  else if (normalized.endsWith('s') && normalized.length > 2 &&
           !exceptions.includes(normalized)) {
    normalized = normalized.slice(0, -1);
  }

  return normalized.trim();
}
