import { useMemo, useState } from "react";
import type { DocSection, Verdict } from "../types";
import { Markdown, VerdictChip } from "./Markdown";

const FILTERS: { id: Verdict | "all"; label: string }[] = [
  { id: "rejected", label: "Rejected" },
  { id: "landed", label: "Landed" },
  { id: "mixed", label: "Mixed" },
  { id: "all", label: "Everything with a verdict" }
];

/**
 * Every experiment that reached a verdict, rejections first.
 *
 * This is the view the repository has no other form of: the log records failures as carefully as
 * wins, but they are scattered across sixty chapters ordered by when they happened.
 */
export function Graveyard({ sections }: { sections: DocSection[] }) {
  const [filter, setFilter] = useState<Verdict | "all">("rejected");
  const [query, setQuery] = useState("");

  const decided = useMemo(
    () => sections.filter((s) => s.verdict !== "neutral"),
    [sections]
  );

  const shown = useMemo(() => {
    const needle = query.trim().toLowerCase();
    return decided
      .filter((s) => filter === "all" || s.verdict === filter)
      .filter(
        (s) =>
          !needle ||
          s.title.toLowerCase().includes(needle) ||
          s.summary.toLowerCase().includes(needle)
      );
  }, [decided, filter, query]);

  const counts = useMemo(() => {
    const out: Record<string, number> = {};
    for (const s of decided) out[s.verdict] = (out[s.verdict] ?? 0) + 1;
    return out;
  }, [decided]);

  return (
    <section>
      <h2 style={{ fontSize: 28, letterSpacing: "-0.02em", margin: "40px 0 10px" }}>Experiments</h2>
      <p className="section-lead">
        Every change in the log that reached a verdict: {counts.rejected ?? 0} rejected,{" "}
        {counts.landed ?? 0} landed, {counts.mixed ?? 0} mixed. Each was built and measured against
        its own control. They are scattered across sixty chapters ordered by when they were tried,
        so this collects them.
      </p>

      <div className="filters">
        {FILTERS.map((f) => (
          <button
            key={f.id}
            className={filter === f.id ? "active" : ""}
            aria-pressed={filter === f.id}
            onClick={() => setFilter(f.id)}
          >
            {f.label}
            {f.id !== "all" && <span style={{ color: "var(--text-muted)", marginLeft: 6 }}>{counts[f.id] ?? 0}</span>}
          </button>
        ))}
        <input
          type="search"
          value={query}
          placeholder="Filter by title…"
          onChange={(e) => setQuery(e.target.value)}
          style={{
            marginLeft: "auto",
            background: "var(--surface-1)",
            border: "1px solid var(--grid)",
            borderRadius: 8,
            color: "inherit",
            font: "inherit",
            fontSize: 14,
            padding: "6px 12px",
            minWidth: 220
          }}
        />
      </div>

      {shown.length === 0 && <p className="empty">Nothing matches.</p>}

      {shown.map((section) => (
        <details className="evidence-item" key={section.path}>
          <summary>
            <span style={{ flex: 1 }}>{section.title}</span>
            <VerdictChip verdict={section.verdict} />
          </summary>
          <p className="summary-line">
            {section.chapter !== section.title && (
              <span className="where" style={{ display: "block", marginBottom: 4 }}>
                {section.chapter}
              </span>
            )}
            {section.summary}
          </p>
          <div className="evidence-body">
            <Markdown>{section.markdown}</Markdown>
          </div>
        </details>
      ))}
    </section>
  );
}
