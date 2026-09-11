import { Fragment, useMemo, useRef, useState } from "react";
import { spanOf, stamp } from "../lib/dates";
import { isExperiment, verdictCounts } from "../lib/evidence";
import { buildIndex, markTerms, parseQuery, search } from "../lib/search";
import type { DocSection, Verdict } from "../types";
import { Recorded, RecordedDetail } from "./dates";
import { FilterButton } from "./FilterButton";
import { Markdown, VerdictChip } from "./Markdown";

const FILTERS: { id: Verdict | "all"; label: string }[] = [
  { id: "rejected", label: "Rejected" },
  { id: "landed", label: "Landed" },
  { id: "mixed", label: "Mixed" },
  { id: "all", label: "Everything with a verdict" }
];

/** The query marked up inside a piece of text, so a title hit is as legible as a body one. */
function Highlighted({ text, terms }: { text: string; terms: string[] }) {
  return markTerms(text, terms).map((run, i) =>
    run.marked ? <mark key={i}>{run.text}</mark> : <Fragment key={i}>{run.text}</Fragment>
  );
}

/**
 * Every experiment that reached a verdict, rejections first.
 *
 * This is the view the repository has no other form of: the log records failures as carefully as
 * wins, but they are scattered across sixty chapters ordered by when they happened. The search is
 * in `lib/search.ts`.
 */
export function Graveyard({ sections }: { sections: DocSection[] }) {
  const [filter, setFilter] = useState<Verdict | "all">("rejected");
  const [query, setQuery] = useState("");
  const [oldestFirst, setOldestFirst] = useState(false);
  const field = useRef<HTMLInputElement>(null);

  const decided = useMemo(() => sections.filter(isExperiment), [sections]);
  const index = useMemo(() => buildIndex(decided), [decided]);
  const terms = useMemo(() => parseQuery(query), [query]);
  const { hits, hidden } = useMemo(
    () => search(index, terms, filter, oldestFirst),
    [index, terms, filter, oldestFirst]
  );
  const counts = useMemo(() => verdictCounts(decided), [decided]);
  const range = useMemo(() => spanOf(decided.map((s) => s.history?.recorded)), [decided]);

  return (
    <section>
      <h2 className="view-title">Experiments</h2>
      <p className="section-lead">
        Every change in the log that reached a verdict: {counts.rejected} rejected, {counts.landed}{" "}
        landed, {counts.mixed} mixed. Each was built and measured against its own control. They are
        scattered across sixty chapters ordered by when they were tried, so this collects them.
        {range && (
          <>
            {" "}
            The dates are the commits that recorded each result rather than a date line in the
            document: {range}.
          </>
        )}
      </p>

      {/* The search is the first control rather than the last, because the question a reader
          arrives with is a symptom or a number, and almost none of those are in a title. */}
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
          placeholder="Search every write-up in full…"
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
          {hits.length === 0
            ? "No experiment matches."
            : `${hits.length} of ${decided.length} ${hits.length === 1 ? "experiment matches" : "experiments match"}.`}
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
          <FilterButton
            key={f.id}
            active={filter === f.id}
            count={f.id === "all" ? undefined : counts[f.id]}
            onClick={() => setFilter(f.id)}
          >
            {f.label}
          </FilterButton>
        ))}
        <button
          className="sort"
          onClick={() => setOldestFirst((v) => !v)}
          title="The order the experiments were tried in"
        >
          {oldestFirst ? "Oldest first" : "Newest first"}
        </button>
      </div>

      {hits.length === 0 && <p className="empty">Nothing matches.</p>}

      {hits.map((entry, i) => {
        const section = entry.section;
        // A day rule, drawn when the list moves off one. Several of these were tried in the same
        // sitting, and that is a fact about them worth being able to see.
        const day = stamp(section.history?.recorded, false);
        const newDay = day !== "—" && day !== stamp(hits[i - 1]?.section.history?.recorded, false);
        return (
          <Fragment key={section.path}>
            {newDay && <h3 className="day-rule">{day}</h3>}
            <details className="evidence-item">
              {/* The snippet lives in the summary rather than the body: a closed row is the state
                  a search result is read in, and a body hit that only says "it matched" is not
                  worth returning. */}
              <summary>
                <span className="summary-head">
                  <span style={{ flex: 1 }}>
                    <Highlighted text={section.title} terms={terms} />
                  </span>
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
                    <Highlighted text={section.chapter} terms={terms} />
                  </span>
                )}
                <Highlighted text={section.summary} terms={terms} />
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
