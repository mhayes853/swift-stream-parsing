import type { DocHistory } from "../types";

// When each experiment happened.
//
// The dates are the log's own git history — the commit that wrote a section down, and the last one
// that rewrote it — extracted by `HistoryExtractor` rather than typed into the document. Nothing
// here parses with `Date`: an ISO string carries the offset the author was at, and `new Date(...)`
// would re-render that in the reader's zone, so one commit made at 15:41 in Los Angeles would read
// as 23:41 in Berlin. An engineering log is a record of when somebody was working, so the author's
// clock is the one that means something and the string is sliced rather than converted.

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const COMMIT = "https://github.com/mhayes853/swift-stream-parsing/commit";

interface Parts {
  year: string;
  month: string;
  day: string;
  time: string;
  offset: string;
}

function parts(iso: string): Parts | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}:\d{2})(?::\d{2})?(.*)$/.exec(iso);
  if (!m) return null;
  return { year: m[1], month: m[2], day: m[3], time: m[4], offset: m[5] ?? "" };
}

/** `29 Aug 2026, 15:41`, or `29 Aug 2026` without the clock. */
export function stamp(iso: string | undefined, withTime = true): string {
  if (!iso) return "—";
  const p = parts(iso);
  if (!p) return iso;
  const day = `${Number(p.day)} ${MONTHS[Number(p.month) - 1]} ${p.year}`;
  return withTime ? `${day}, ${p.time}` : day;
}

/** Sortable: the raw ISO strings sort correctly only within one offset, so compare instants. */
export function instant(iso: string | undefined): number {
  return iso ? Date.parse(iso) || 0 : 0;
}

/** `Aug 11 – Sep 1, 2026`, for a span of the log. */
export function span(from: string | undefined, to: string | undefined): string {
  if (!from || !to) return "";
  const a = parts(from);
  const b = parts(to);
  if (!a || !b) return "";
  const short = (p: Parts) => `${MONTHS[Number(p.month) - 1]} ${Number(p.day)}`;
  return a.year === b.year
    ? `${short(a)} – ${short(b)}, ${b.year}`
    : `${short(a)} ${a.year} – ${short(b)} ${b.year}`;
}

/**
 * One line of provenance: when the section was written, and whether it was rewritten afterwards.
 *
 * A revision count is worth showing rather than hiding because it separates two things the reader
 * would otherwise have to guess between — a result written once and left alone, and one that was
 * revisited when a later change moved its numbers.
 */
export function Recorded({ history }: { history?: DocHistory }) {
  if (!history) return null;
  const rewritten = history.revisions > 1 && history.revised !== history.recorded;
  return (
    <span className="dated">
      <time dateTime={history.recorded} title={`${history.recordedSubject} (${history.recordedCommit})`}>
        {stamp(history.recorded)}
      </time>
      {rewritten && (
        <>
          <span className="dated-sep">·</span>
          <span
            className="dated-revised"
            title={`Last rewritten by: ${history.revisedSubject} (${history.revisedCommit})`}
          >
            revised {history.revisions - 1}× through {stamp(history.revised, false)}
          </span>
        </>
      )}
    </span>
  );
}

/** The same, with the commits as links. Used where there is room for them. */
export function RecordedDetail({ history }: { history?: DocHistory }) {
  if (!history) return null;
  const rewritten = history.revisions > 1 && history.revised !== history.recorded;
  return (
    <span className="dated">
      Recorded{" "}
      <time dateTime={history.recorded}>{stamp(history.recorded)}</time> in{" "}
      <a href={`${COMMIT}/${history.recordedCommit}`} target="_blank" rel="noreferrer" title={history.recordedSubject}>
        <code>{history.recordedCommit.slice(0, 7)}</code>
      </a>
      {rewritten ? (
        <>
          {", rewritten "}
          {history.revisions - 1}× since, last on{" "}
          <time dateTime={history.revised}>{stamp(history.revised)}</time> in{" "}
          <a
            href={`${COMMIT}/${history.revisedCommit}`}
            target="_blank"
            rel="noreferrer"
            title={history.revisedSubject}
          >
            <code>{history.revisedCommit.slice(0, 7)}</code>
          </a>
        </>
      ) : (
        ", and not rewritten since"
      )}
      .
    </span>
  );
}
