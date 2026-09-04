import { useMemo, useState } from "react";
import type { DocSection, Measurement } from "../types";

const NAMES: Record<string, string> = {
  canada: "canada.json",
  twitter: "twitter.json",
  twitterescaped: "twitterescaped.json",
  citm_catalog: "citm_catalog.json",
  "gsoc-2018": "gsoc-2018.json",
  github_events: "github_events.json",
  llm_message: "llm_message.json",
  mesh: "mesh",
  qwen: "Qwen 3 tool call",
  pretty_printed: "pretty printed",
  matrix: "Payloads.matrix",
  unicode_escapes: "unicode escapes"
};

interface Row extends Measurement {
  section: DocSection;
}

/**
 * Every delta ever recorded against one payload.
 *
 * Diverging encoding: a gain and a loss are opposite polarities around a true zero, so the bar
 * takes the blue/red pair with a neutral midpoint rather than a sequential ramp. The signed number
 * is printed beside every bar, so polarity never rests on hue alone.
 */
export function Payloads({ sections }: { sections: DocSection[] }) {
  const rows = useMemo(() => {
    const out: Row[] = [];
    for (const section of sections) {
      for (const m of section.measurements) {
        if (m.isDelta) out.push({ ...m, section });
      }
    }
    return out;
  }, [sections]);

  const payloads = useMemo(() => {
    const counts = new Map<string, number>();
    for (const r of rows) counts.set(r.payload, (counts.get(r.payload) ?? 0) + 1);
    return [...counts.entries()].sort((a, b) => b[1] - a[1]);
  }, [rows]);

  const [selected, setSelected] = useState(payloads[0]?.[0] ?? "canada");
  const mine = useMemo(
    () => rows.filter((r) => r.payload === selected).sort((a, b) => b.value - a.value),
    [rows, selected]
  );

  const extent = Math.max(1, ...mine.map((r) => Math.abs(r.value)));

  return (
    <section>
      <h2 style={{ fontSize: 28, letterSpacing: "-0.02em", margin: "40px 0 10px" }}>By payload</h2>
      <p className="section-lead">
        The same corpus runs under every experiment, so each payload accumulates a history. This is
        every signed delta the log records against one file, gains and regressions alike. Data shape
        is a first-order term: a change that gains 20% on <code>citm_catalog.json</code> can lose 35%
        on a payload it never executes on.
      </p>

      <div className="filters">
        {payloads.map(([id, count]) => (
          <button key={id} className={selected === id ? "active" : ""} aria-pressed={selected === id} onClick={() => setSelected(id)}>
            {NAMES[id] ?? id}
            <span style={{ color: "var(--text-muted)", marginLeft: 6 }}>{count}</span>
          </button>
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
              const positive = row.value >= 0;
              const width = (Math.abs(row.value) / extent) * 50;
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
                          background: positive ? "var(--diverge-pos)" : "var(--diverge-neg)",
                          left: positive ? "50%" : `${50 - width}%`,
                          width: `${width}%`
                        }}
                      />
                    </div>
                  </td>
                  <td className={`delta ${positive ? "pos" : "neg"}`} style={{ textAlign: "right" }}>
                    {positive ? "▲ +" : "▼ "}
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
