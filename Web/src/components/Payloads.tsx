import { useMemo, useState } from "react";
import { deltaRows, divergingBar, payloadCounts, payloadName, rowsFor } from "../lib/payloads";
import type { DocSection } from "../types";
import { FilterButton } from "./FilterButton";

/**
 * Every delta ever recorded against one payload.
 *
 * Diverging encoding: a gain and a loss are opposite polarities around a true zero, so the bar
 * takes the blue/red pair with a neutral midpoint rather than a sequential ramp. The signed number
 * is printed beside every bar, so polarity never rests on hue alone.
 */
export function Payloads({ sections }: { sections: DocSection[] }) {
  const rows = useMemo(() => deltaRows(sections), [sections]);
  const payloads = useMemo(() => payloadCounts(rows), [rows]);
  // Derived rather than initialised from the first render: the content arrives after the view
  // mounts, and a default captured from an empty list would never be revisited.
  const [chosen, setChosen] = useState<string | null>(null);
  const selected = chosen ?? payloads[0]?.[0] ?? "canada";
  const mine = useMemo(() => rowsFor(rows, selected), [rows, selected]);
  const extent = Math.max(1, ...mine.map((r) => Math.abs(r.value)));

  return (
    <section>
      <h2 className="view-title">By payload</h2>
      <p className="section-lead">
        The same corpus runs under every experiment, so each payload accumulates a history. This is
        every signed delta the log records against one file, gains and regressions alike. Data shape
        is a first-order term: a change that gains 20% on <code>citm_catalog.json</code> can lose 35%
        on a payload it never executes on.
      </p>

      <div className="filters">
        {payloads.map(([id, count]) => (
          <FilterButton key={id} active={selected === id} count={count} onClick={() => setChosen(id)}>
            {payloadName(id)}
          </FilterButton>
        ))}
      </div>

      {mine.length === 0 ? (
        <p className="empty">No signed deltas recorded for this payload.</p>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Experiment</th>
              <th>Row</th>
              <th className="bar-cell">Change</th>
              <th style={{ textAlign: "right" }}>Δ</th>
            </tr>
          </thead>
          <tbody>
            {mine.map((row, i) => {
              const bar = divergingBar(row.value, extent);
              return (
                <tr key={i}>
                  <td style={{ maxWidth: 300 }}>
                    {row.section.title}
                    {row.section.chapter !== row.section.title && (
                      <div style={{ color: "var(--text-muted)", fontSize: 12 }}>{row.section.chapter}</div>
                    )}
                  </td>
                  <td style={{ color: "var(--text-muted)", fontSize: 12.5 }}>
                    {[row.rowLabel, row.column].filter(Boolean).join(" · ")}
                  </td>
                  <td className="bar-cell">
                    <div className="bar-track">
                      <div className="bar-zero" style={{ left: "50%" }} />
                      <div
                        className="bar-fill"
                        style={{
                          background: bar.positive ? "var(--diverge-pos)" : "var(--diverge-neg)",
                          left: `${bar.left}%`,
                          width: `${bar.width}%`
                        }}
                      />
                    </div>
                  </td>
                  <td className={`delta ${bar.positive ? "pos" : "neg"}`} style={{ textAlign: "right" }}>
                    {bar.positive ? "▲ +" : "▼ "}
                    {row.value.toFixed(1)}%
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </section>
  );
}
