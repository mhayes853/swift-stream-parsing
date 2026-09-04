import { useEffect, useMemo, useState } from "react";
import pipelineData from "../content/pipeline.json";
import { span } from "./components/dates";
import { DetailPanel } from "./components/DetailPanel";
import { FlowChart } from "./components/FlowChart";
import { Graveyard } from "./components/Graveyard";
import { Payloads } from "./components/Payloads";
import { loadContent, loadTraces } from "./data";
import type { ContentBundle, DocSection, Pipeline, PipelineNode, TraceBundle } from "./types";

const pipeline = pipelineData as Pipeline;
type View = "flow" | "graveyard" | "payloads";

export function App() {
  const [content, setContent] = useState<ContentBundle | null>(null);
  const [traces, setTraces] = useState<TraceBundle | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selected, setSelected] = useState<PipelineNode | null>(null);
  const [view, setView] = useState<View>("flow");
  const [theme, setTheme] = useState(() => document.documentElement.dataset.theme ?? "dark");

  useEffect(() => {
    loadContent().then(setContent, (e) => setError(String(e)));
    loadTraces().then(setTraces, (e) => setError(String(e)));
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
  }, [theme]);

  const sections = useMemo(() => {
    const map = new Map<string, DocSection>();
    for (const s of content?.doc.sections ?? []) map.set(s.path, s);
    return map;
  }, [content]);

  if (error) {
    return (
      <div className="page">
        <p className="callout warn" style={{ marginTop: 60 }}>
          Could not load the generated content: {error}
          <br />
          Run <code>./Web/generate</code> from the repository root, then reload.
        </p>
      </div>
    );
  }

  return (
    <>
      <header className="topbar">
        <div className="brand">
          swift-stream-parsing
          <small>parser architecture explorer</small>
        </div>
        <nav className="tabs">
          <button aria-pressed={view === "flow"} onClick={() => setView("flow")}>
            Parse path
          </button>
          <button aria-pressed={view === "graveyard"} onClick={() => setView("graveyard")}>
            Experiments
          </button>
          <button aria-pressed={view === "payloads"} onClick={() => setView("payloads")}>
            Payloads
          </button>
        </nav>
        <button onClick={() => setTheme(theme === "dark" ? "light" : "dark")} aria-label="Toggle colour scheme">
          {theme === "dark" ? "☾" : "☀"}
        </button>
      </header>

      <main className="page">
        {view === "flow" && (
          <>
            <section className="intro">
              <h1>The parse path</h1>
              <p>
                Each node is a step a chunk of bytes passes through; each arrow is labelled with
                what it does, or with the condition under which it is taken. Numbers appear where
                the order is real — a switch tests its arms in the order they are written. Hover a
                node to read how it reaches the things it calls; select one to open the evidence
                under it: the experiments that settled its shape, the source, and the assembly.
              </p>
              <div className="stat-row">
                <Stat value={String(pipeline.nodes.length)} label="steps" />
                <Stat value={content ? String(content.stats.sectionCount) : "—"} label="documented sections" />
                <Stat value={String(verdictTotal(content))} label="experiments with a verdict" />
                <Stat value={content ? String(content.stats.tableCount) : "—"} label="measurement tables" />
                <Stat value={content ? String(content.stats.declCount) : "—"} label="declarations indexed" />
                <Stat
                  value={
                    content ? span(content.stats.firstRecorded, content.stats.lastRecorded) || "—" : "—"
                  }
                  label="the log's span"
                />
              </div>
              <FlowLegend />
            </section>

            <FlowChart
              pipeline={pipeline}
              sections={sections}
              selected={selected}
              onSelect={setSelected}
            />

            <p className="viz-note">
              Generated from <code>NEW_ARCHITECTURE.md</code> and the source comments by{" "}
              <code>./Web/generate</code>
              {content ? ` on ${content.generatedAt.slice(0, 10)}` : ""}. The prose per step is in{" "}
              <code>Web/content/pipeline.json</code>; everything under it resolves out of the
              repository. Animations replay traces recorded from the shipped kernels
              {traces ? ` on ${traces.arch}` : ""}. Every section is dated by the commit that wrote
              it, recovered from the log's git history rather than written into it.
            </p>
          </>
        )}
        {view === "graveyard" && <Graveyard sections={content?.doc.sections ?? []} />}
        {view === "payloads" && <Payloads sections={content?.doc.sections ?? []} />}
      </main>

      {selected && (
        <DetailPanel
          node={selected}
          sections={sections}
          traces={traces}
          onClose={() => setSelected(null)}
        />
      )}
    </>
  );
}

function verdictTotal(content: ContentBundle | null): number | string {
  if (!content) return "—";
  const v = content.stats.verdictCounts;
  return (v.landed ?? 0) + (v.rejected ?? 0) + (v.mixed ?? 0);
}

function Stat({ value, label }: { value: string; label: string }) {
  return (
    <div className="stat">
      <div className="value">{value}</div>
      <div className="label">{label}</div>
    </div>
  );
}

function FlowLegend() {
  return (
    <div className="legend flow-legend">
      <span>
        <svg width="30" height="8" aria-hidden="true">
          <line x1="0" y1="4" x2="30" y2="4" stroke="var(--text-muted)" strokeWidth="1.5" />
        </svg>
        always runs, or runs on the labelled condition
      </span>
      <span>
        <svg width="30" height="8" aria-hidden="true">
          <line x1="0" y1="4" x2="30" y2="4" stroke="var(--text-muted)" strokeWidth="1.5" strokeDasharray="5 4" />
        </svg>
        returns
      </span>
      <span>
        <svg width="30" height="8" aria-hidden="true">
          <line x1="0" y1="4" x2="30" y2="4" stroke="var(--text-muted)" strokeWidth="1.5" strokeDasharray="1.5 3.5" />
        </svg>
        detail of the same work
      </span>
      <span>
        <span className="flow-key viz">▶</span> has an animation
      </span>
      <span>
        <span className="flow-key landed">n↑</span> landed experiments
      </span>
      <span>
        <span className="flow-key rejected">n✕</span> rejected experiments
      </span>
    </div>
  );
}
