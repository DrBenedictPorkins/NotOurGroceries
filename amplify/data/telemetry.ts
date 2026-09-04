/**
 * One way to write a log line, so the logs can be queried instead of read.
 *
 * Every handler used to log in its own dialect — `[PARSE] request` with a
 * JSON blob, `[INFER] Received request:` with a stringified event, bare
 * template strings in the household functions. All of it was legible to a
 * person scrolling and useless to a query, which is why the cost-per-household
 * question sat unanswered for a month while the data to answer it was already
 * on disk.
 *
 * The functions here are configured with `logFormat: JSON` (see `backend.ts`),
 * so passing an **object** to console puts it in the `message` field as real
 * structure rather than a string. Logs Insights then reads it directly:
 *
 *   filter message.event = "ai.parse" | stats sum(message.tokens.output)
 *
 * Two rules, both load-bearing:
 *
 * 1. **Names are `noun.verb`, past tense, and never change.** A renamed event
 *    silently truncates every historical query that used it.
 * 2. **No user content, ever.** Item names, notes, transcripts and photos are
 *    the user's, and `docs/privacy.html` promises the logs do not hold them.
 *    Log the shape of the thing — how many, how long, how much — never the
 *    thing. `count`, `chars` and `bytes` answer the questions we actually have.
 */

type Fields = Record<string, unknown>;

/**
 * A completed unit of work worth counting.
 *
 * INFO level. This is the stream the analysis reads; keep it to things that
 * happened, not things that are being attempted.
 */
export function logEvent(event: string, fields: Fields = {}): void {
  console.log({ event, ...fields });
}

/**
 * Something recoverable that a human should see in aggregate — a truncated
 * input, a retried collision, a refused caller.
 */
export function logWarning(event: string, fields: Fields = {}): void {
  console.warn({ event, ...fields });
}

/**
 * A failure. `error` is reduced to name and message: stacks are noise in a
 * query and can carry fragments of the input that produced them.
 */
export function logFailure(event: string, error: unknown, fields: Fields = {}): void {
  const detail =
    error instanceof Error
      ? { errorName: error.name, errorMessage: error.message }
      : { errorName: 'NonError', errorMessage: String(error) };
  console.error({ event, ...detail, ...fields });
}

/**
 * Anthropic token usage, flattened into the four numbers that carry cost.
 *
 * `output` is the one that was missing everywhere, and it is the expensive
 * half — output is 5x input on every Claude model. Without it there is no cost
 * per call, only a lower bound.
 */
export function tokenUsage(usage: {
  input_tokens?: number | null;
  output_tokens?: number | null;
  cache_creation_input_tokens?: number | null;
  cache_read_input_tokens?: number | null;
}): Fields {
  return {
    tokens: {
      input: usage.input_tokens ?? 0,
      output: usage.output_tokens ?? 0,
      cacheWrite: usage.cache_creation_input_tokens ?? 0,
      cacheRead: usage.cache_read_input_tokens ?? 0,
    },
  };
}
