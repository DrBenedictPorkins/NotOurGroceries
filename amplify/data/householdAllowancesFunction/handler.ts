import type { Schema } from '../resource';
import { requireHousehold } from '../requireHousehold';
import { loadAllowance, summarize } from '../allowance';

type Handler = Schema['householdAllowances']['functionHandler'];

/**
 * Where the caller's household stands: entitlement, what it has used this
 * period, the caps, and when the period rolls. The app asks on launch, on
 * return to the foreground, and whenever the allowances page opens.
 *
 * Reading through here rather than the row directly is what lets the period
 * roll lazily — the first look after the boundary is what zeroes the counters —
 * and keeps the caps in one server-side file.
 */
export const handler: Handler = async (event) => {
  const [householdId] = requireHousehold(event);
  const row = await loadAllowance(householdId);
  return summarize(row);
};
