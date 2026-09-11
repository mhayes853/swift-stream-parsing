import type { DocHistory } from "../types";

// When each experiment happened.
//
// The dates are the log's own git history — the commit that wrote a section down, and the last one
// that rewrote it — extracted by `HistoryExtractor` rather than typed into the document. Nothing
// here parses with `Date` for display: an ISO string carries the offset the author was at, and
// `new Date(...)` would re-render that in the reader's zone, so one commit made at 15:41 in Los
// Angeles would read as 23:41 in Berlin. An engineering log is a record of when somebody was
// working, so the author's clock is the one that means something and the string is sliced rather
// than converted.

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

interface Parts {
  year: string;
  month: string;
  day: string;
  time: string;
}

function parts(iso: string): Parts | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}:\d{2})/.exec(iso);
  return m ? { year: m[1], month: m[2], day: m[3], time: m[4] } : null;
}

const monthName = (p: Parts) => MONTHS[Number(p.month) - 1];

/** `29 Aug 2026, 15:41`, or `29 Aug 2026` without the clock. */
export function stamp(iso: string | undefined, withTime = true): string {
  if (!iso) return "—";
  const p = parts(iso);
  if (!p) return iso;
  const day = `${Number(p.day)} ${monthName(p)} ${p.year}`;
  return withTime ? `${day}, ${p.time}` : day;
}

/** Sortable: the raw ISO strings sort correctly only within one offset, so compare instants. */
export function instant(iso: string | undefined): number {
  return iso ? Date.parse(iso) || 0 : 0;
}

/** `Aug 11 – Sep 1, 2026`, for a span of the log. */
export function span(from: string | undefined, to: string | undefined): string {
  const a = from ? parts(from) : null;
  const b = to ? parts(to) : null;
  if (!a || !b) return "";
  const short = (p: Parts) => `${monthName(p)} ${Number(p.day)}`;
  return a.year === b.year
    ? `${short(a)} – ${short(b)}, ${b.year}`
    : `${short(a)} ${a.year} – ${short(b)} ${b.year}`;
}

/** The span from the earliest to the latest of these recorded dates, or "" with fewer than two. */
export function spanOf(dates: (string | undefined)[]): string {
  const known = dates.filter((d): d is string => !!d).sort();
  return known.length > 1 ? span(known[0], known[known.length - 1]) : "";
}

/**
 * Whether the section was rewritten after it was recorded. A revision count is worth showing
 * rather than hiding because it separates a result written once and left alone from one that was
 * revisited when a later change moved its numbers.
 */
export function wasRewritten(history: DocHistory): boolean {
  return history.revisions > 1 && history.revised !== history.recorded;
}

export function commitURL(sha: string): string {
  return `https://github.com/mhayes853/swift-stream-parsing/commit/${sha}`;
}
