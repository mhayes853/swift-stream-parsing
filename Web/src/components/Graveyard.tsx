import { Fragment, useMemo, useRef, useState } from "react";
import type { DocSection, Verdict } from "../types";
import { Recorded, RecordedDetail, instant, span, stamp } from "./dates";
import { Markdown, VerdictChip } from "./Markdown";

const FILTERS: { id: Verdict | "all"; label: string }[] = [
  { id: "rejected", label: "Rejected" },
  { id: "landed", label: "Landed" },
  { id: "mixed", label: "Mixed" },
  { id: "all", label: "Everything with a verdict" }
];

/** How much of the body to draw either side of a hit. Asymmetric: what follows a term usually
 *  carries the number, and what precedes it is usually the run-up. */
const LEAD = 70;
const TRAIL = 130;

/** A section with its body flattened once, so typing does not re-walk the markdown per keystroke. */
interface Indexed {
  section: DocSection;
  /** The body as one line: a snippet's offsets are then offsets into what actually gets drawn. */
  body: string;
  bodyLower: string;
  titleLower: string;
  summaryLower: string;
  chapterLower: string;
}

interface Hit {
  section: DocSection;
  /** Where the strongest match was, which is what decides whether a snippet is worth drawing. */
  where: "title" | "summary" | "body";
  snippet?: { before: string; match: string; after: string };
  /** Occurrences in the body of the first term that hit it. A term that appears eleven times is
   *  the section's subject; one that appears once is an aside, and the reader can tell them
   *  apart before opening anything. */
  count: number;
}

function index(sections: DocSection[]): Indexed[] {
  return sections.map((section) => {
    // Markdown syntax comes off first, so the snippet reads as prose rather than as source and a
    // query can span a span of code -- "shrn movemask" is two words in the log with a backtick
    // between them. Stripping before flattening keeps a hit's offset an offset into what is drawn.
    const body = `${section.title}\n${section.chapter}\n${section.summary}\n${section.markdown}`
      .replace(/```[a-z]*\n?/g, "")
      .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
      .replace(/[`*#>]/g, "")
      .replace(/\s+/g, " ")
      .trim();
    return {
      section,
      body,
      bodyLower: body.toLowerCase(),
      titleLower: section.title.toLowerCase(),
      summaryLower: section.summary.toLowerCase(),
      chapterLower: section.chapter.toLowerCase()
    };
  });
}

/** Every term has to appear somewhere in the entry — the body includes the title, chapter and
 *  summary, so a query spread across a title and a paragraph still matches. */
function matches(entry: Indexed, terms: string[]): boolean {
  return terms.every((t) => entry.bodyLower.includes(t));
}

function hit(entry: Indexed, terms: string[]): Hit {
  if (terms.every((t) => entry.titleLower.includes(t))) {
    return { section: entry.section, where: "title", count: 0 };
  }
  if (terms.every((t) => entry.summaryLower.includes(t) || entry.chapterLower.includes(t))) {
    return { section: entry.section, where: "summary", count: 0 };
  }

  // The body is the interesting case, and the one the old title-only filter could not reach: the
  // reader needs to see *what* matched, because a body hit says nothing on its own.
  const term = terms.find((t) => entry.bodyLower.includes(t)) ?? terms[0];
  const at = entry.bodyLower.indexOf(term);
  let count = 0;
  for (let i = at; i >= 0; i = entry.bodyLower.indexOf(term, i + term.length)) count++;

  // Widened to the nearest space on each side, so a snippet never opens or closes mid-word.
  let from = Math.max(0, at - LEAD);
  if (from > 0) {
    const space = entry.body.indexOf(" ", from);
    from = space >= 0 && space < at ? space + 1 : from;
  }
  let to = Math.min(entry.body.length, at + term.length + TRAIL);
  if (to < entry.body.length) {
    const space = entry.body.lastIndexOf(" ", to);
    to = space > at + term.length ? space : to;
  }

  return {
    section: entry.section,
    where: "body",
    count,
    snippet: {
      before: (from > 0 ? "…" : "") + entry.body.slice(from, at),
      match: entry.body.slice(at, at + term.length),
      after: entry.body.slice(at + term.length, to) + (to < entry.body.length ? "…" : "")
    }
  };
}

/** The query marked up inside a title, so a title hit is as legible as a body one. */
function highlight(text: string, terms: string[]) {
  if (terms.length === 0) return text;
  const lower = text.toLowerCase();
  // One pass, taking whichever term starts earliest at each position, so overlapping terms do not
  // produce nested marks.
  const out: (string | React.ReactElement)[] = [];
  let at = 0;
  let key = 0;
  while (at < text.length) {
    let best = -1;
    let length = 0;
    for (const t of terms) {
      const found = lower.indexOf(t, at);
      if (found >= 0 && (best < 0 || found < best)) {
        best = found;
        length = t.length;
      }
    }
    if (best < 0) break;
    if (best > at) out.push(text.slice(at, best));
    out.push(<mark key={key++}>{text.slice(best, best + length)}</mark>);
    at = best + length;
  }
  if (at < text.length) out.push(text.slice(at));
  return out;
}

/**
 * Every experiment that reached a verdict, rejections first.
 *
 * This is the view the repository has no other form of: the log records failures as carefully as
 * wins, but they are scattered across sixty chapters ordered by when they happened. The search is
 * over the whole of each section rather than its title, because what a reader arrives with is a
 * symptom or a number — "movemask", "swift_beginAccess", "29%" — and almost none of those are in
 * a title.
 */
export function Graveyard({ sections }: { sections: DocSection[] }) {
  const [filter, setFilter] = useState<Verdict | "all">("rejected");
  const [query, setQuery] = useState("");
  // Newest first by default. The log is ordered by when things were tried, and this view is the
  // one place that ordering is recoverable once the chapters have been pulled apart.
  const [oldestFirst, setOldestFirst] = useState(false);
  const field = useRef<HTMLInputElement>(null);

  const decided = useMemo(() => sections.filter((s) => s.verdict !== "neutral"), [sections]);
  const indexed = useMemo(() => index(decided), [decided]);
  const terms = useMemo(
    () => query.trim().toLowerCase().split(/\s+/).filter(Boolean),
    [query]
  );

  const found = useMemo(
    () => (terms.length === 0 ? indexed : indexed.filter((e) => matches(e, terms))),
    [indexed, terms]
  );

  const shown = useMemo(
    () =>
      found
        .filter((e) => filter === "all" || e.section.verdict === filter)
        .map((e) => (terms.length === 0 ? { section: e.section, where: "title" as const, count: 0 } : hit(e, terms)))
        .sort((a, b) => {
          const d = instant(a.section.history?.recorded) - instant(b.section.history?.recorded);
          return oldestFirst ? d : -d;
        }),
    [found, filter, terms, oldestFirst]
  );

  // A full-text search that silently drops matches behind the verdict filter would be a trap, so
  // the ones it is hiding are counted and offered rather than left to be discovered.
  const hidden = found.length - shown.length;

  const counts = useMemo(() => {
    const out: Record<string, number> = {};
    for (const s of decided) out[s.verdict] = (out[s.verdict] ?? 0) + 1;
    return out;
  }, [decided]);

  const dates = useMemo(
    () => decided.map((s) => s.history?.recorded).filter((d): d is string => !!d).sort(),
    [decided]
  );

  return (
    <section>
      <h2 style={{ fontSize: 28, letterSpacing: "-0.02em", margin: "40px 0 10px" }}>Experiments</h2>
      <p className="section-lead">
        Every change in the log that reached a verdict: {counts.rejected ?? 0} rejected,{" "}
        {counts.landed ?? 0} landed, {counts.mixed ?? 0} mixed. Each was built and measured against
        its own control. They are scattered across sixty chapters ordered by when they were tried,
        so this collects them.
        {dates.length > 1 && (
          <>
            {" "}
            The dates are the commits that recorded each result rather than a date line in the
            document: {span(dates[0], dates[dates.length - 1])}.
          </>
        )}
      </p>

      <div className="search">
        <svg className="search-icon" viewBox="0 0 16 16" aria-hidden="true">
          <circle cx="7" cy="7" r="4.5" fill="none" stroke="currentColor" strokeWidth="1.6" />
          <path d="M10.4 10.4 L14 14" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
        <input
          ref={field}
          type="search"
          value={query}
          aria-label="Search every experiment"
          placeholder="Search titles, summaries and the whole of every write-up…"
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Escape") setQuery("");
          }}
        />
        {query && (
          <button
            className="search-clear"
            aria-label="Clear the search"
            onClick={() => {
              setQuery("");
              field.current?.focus();
            }}
          >
            ✕
          </button>
        )}
      </div>

      {terms.length > 0 && (
        <p className="search-status">
          {shown.length === 0
            ? "No experiment matches."
            : `${shown.length} of ${decided.length} ${shown.length === 1 ? "experiment matches" : "experiments match"}.`}
          {hidden > 0 && (
            <>
              {" "}
              <button className="linky" onClick={() => setFilter("all")}>
                {hidden} more {hidden === 1 ? "is" : "are"} behind the verdict filter — search
                everything
              </button>
            </>
          )}
        </p>
      )}

      <div className="filters">
        {FILTERS.map((f) => (
          <button
            key={f.id}
            className={filter === f.id ? "active" : ""}
            aria-pressed={filter === f.id}
            onClick={() => setFilter(f.id)}
          >
            {f.label}
            {f.id !== "all" && (
              <span style={{ color: "var(--text-muted)", marginLeft: 6 }}>{counts[f.id] ?? 0}</span>
            )}
          </button>
        ))}
        <button
          className="sort"
          onClick={() => setOldestFirst((v) => !v)}
          title="The order the experiments were tried in"
        >
          {oldestFirst ? "Oldest first" : "Newest first"}
        </button>
      </div>

      {shown.length === 0 && <p className="empty">Nothing matches.</p>}

      {shown.map((entry, i) => {
        const section = entry.section;
        // A day rule, drawn when the list moves off one. Several of these were tried in the same
        // sitting, and that is a fact about them worth being able to see.
        const day = stamp(section.history?.recorded, false);
        const newDay =
          day !== "—" && day !== stamp(shown[i - 1]?.section.history?.recorded, false);
        return (
          <Fragment key={section.path}>
            {newDay && <h3 className="day-rule">{day}</h3>}
            <details className="evidence-item">
              {/* The snippet lives in the summary rather than the body: a closed row is the state
                  a search result is read in, and a body hit that only says "it matched" is not
                  worth returning. */}
              <summary>
                <span className="summary-head">
                  <span style={{ flex: 1 }}>{highlight(section.title, terms)}</span>
                  <Recorded history={section.history} />
                  <VerdictChip verdict={section.verdict} />
                </span>
                {entry.snippet && (
                  <span className="snippet">
                    <span className="snippet-count">
                      {entry.count} {entry.count === 1 ? "hit" : "hits"} in the write-up
                    </span>
                    {entry.snippet.before}
                    <mark>{entry.snippet.match}</mark>
                    {entry.snippet.after}
                  </span>
                )}
              </summary>
              <p className="summary-line">
                {section.chapter !== section.title && (
                  <span className="where" style={{ display: "block", marginBottom: 4 }}>
                    {highlight(section.chapter, terms)}
                  </span>
                )}
                {highlight(section.summary, terms)}
              </p>
              <div className="evidence-body">
                <Markdown>{section.markdown}</Markdown>
                {section.history && (
                  <p className="provenance">
                    <RecordedDetail history={section.history} />
                  </p>
                )}
              </div>
            </details>
          </Fragment>
        );
      })}
    </section>
  );
}
