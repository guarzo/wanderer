import type { SystemSignature } from '@/hooks/Mapper/types/signatures';

/**
 * Bookmark colours for the "time since this system was scanned" indicator.
 *
 * `ancient` has no upper bound on purpose. An age that stops rendering past
 * some threshold makes a long-neglected system look identical to one nobody
 * has ever scanned, which is exactly the distinction the indicator exists to
 * draw. Absence of the bookmark means "never scanned", and nothing else.
 */
export const SIGNATURE_AGE_COLORS = {
  fresh: '#388E3C',
  aging: '#E65100',
  stale: '#B71C1C',
  ancient: '#4A148C',
} as const;

/** Age, in hours, at which the label switches from hours to whole days. */
const DAY_HOURS = 24;

export type SignatureAge = {
  /** Epoch millis of the most recent signature timestamp, or 0 if there is none. */
  newestUpdatedAt: number;
  /** Whole hours since that timestamp, or -1 when the system has never been scanned. */
  signatureAgeHours: number;
  bookmarkColor: string;
};

export function getSignatureAgeColor(signatureAgeHours: number): string {
  if (signatureAgeHours < 4) {
    return SIGNATURE_AGE_COLORS.fresh;
  }
  if (signatureAgeHours <= 8) {
    return SIGNATURE_AGE_COLORS.aging;
  }
  if (signatureAgeHours <= 12) {
    return SIGNATURE_AGE_COLORS.stale;
  }
  return SIGNATURE_AGE_COLORS.ancient;
}

/**
 * Renders an age for the bookmark, keeping it to a couple of characters so the
 * marker width stays stable as a system goes stale.
 */
export function formatSignatureAge(signatureAgeHours: number): string {
  if (signatureAgeHours < DAY_HOURS) {
    return `${signatureAgeHours}h`;
  }
  return `${Math.floor(signatureAgeHours / DAY_HOURS)}d`;
}

/**
 * Parses a signature timestamp, treating anything unparseable as absent.
 *
 * The server sends ISO-8601 with an explicit zone, so `new Date` resolves it to
 * a real instant and this needs no correction. It previously sent UTC formatted
 * as `%Y/%m/%d %H:%M:%S` with nothing marking it as UTC, which `new Date` read
 * as *local* time — west of UTC that put every timestamp in the future, drove
 * `now - updated_at` negative, and pinned the age bookmark at "0h" no matter how
 * long ago the system was really scanned. Both readers of that format carried a
 * `getTimezoneOffset()` correction to cancel it out; the format and the
 * corrections were removed together, so there is one parse path again.
 *
 * `new Date('garbage').getTime()` is NaN, and NaN loses every `>` comparison,
 * so an unparseable value would otherwise be indistinguishable from "no
 * timestamp" *and* would suppress the fallback below it.
 */
function parseTimestamp(value?: string | null): number {
  if (!value) {
    return 0;
  }
  const ts = new Date(value).getTime();
  return Number.isFinite(ts) ? ts : 0;
}

function getSignatureTimestamp(s: SystemSignature): number {
  return parseTimestamp(s.updated_at) || parseTimestamp(s.inserted_at);
}

/**
 * Computes how long ago this system was last scanned.
 *
 * Every signature counts, whatever its group and whether or not it is linked to
 * a mapped system: pasting the probe scanner window re-stamps every signature
 * it contains (untouched rows are still sent as updates, see `getActualSigs`),
 * so the newest timestamp in the system is the time of the last paste. An
 * earlier version reused the `group === 'Wormhole' && !linked_system` predicate
 * from `useUnsplashedSignatures`, which answers a different question — "which
 * wormholes are still unmapped" — and so hid the indicator entirely for a
 * system whose signatures were all still unscanned.
 */
export function computeSignatureAge(systemSigs: SystemSignature[] | null | undefined, now: number): SignatureAge {
  const newestUpdatedAt = (systemSigs ?? []).reduce((max, s) => {
    const ts = getSignatureTimestamp(s);
    return ts > max ? ts : max;
  }, 0);

  // No signature carries a usable timestamp, so there is nothing to age. A
  // negative age is the signal to suppress the bookmark; every real age, however
  // large, renders.
  if (newestUpdatedAt === 0) {
    return {
      newestUpdatedAt: 0,
      signatureAgeHours: -1,
      bookmarkColor: SIGNATURE_AGE_COLORS.fresh,
    };
  }

  const signatureAgeHours = Math.max(0, Math.round((now - newestUpdatedAt) / (1000 * 60 * 60)));

  return {
    newestUpdatedAt,
    signatureAgeHours,
    bookmarkColor: getSignatureAgeColor(signatureAgeHours),
  };
}
