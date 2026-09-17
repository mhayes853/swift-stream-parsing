import { useCallback, useEffect, useMemo } from "react";
import pipelineData from "../content/pipeline.json";
import { DetailPanel } from "./components/DetailPanel";
import { FlowChart } from "./components/FlowChart";
import { Graveyard } from "./components/Graveyard";
import { How, Lede, Why } from "./components/Overview";
import { Payloads } from "./components/Payloads";
import { useBundles, useRoute, useTheme } from "./components/hooks";
import { span } from "./lib/dates";
import { experimentTotal, sectionsByPath } from "./lib/evidence";
import { VIEWS } from "./lib/route";
import type { Pipeline, PipelineNode } from "./types";

const pipeline = pipelineData as Pipeline;
const nodeIds = new Set(pipeline.nodes.map((n) => n.id));

export function App() {
  const { content, traces, error } = useBundles();
  const [theme, toggleTheme] = useTheme();
  const { route, go, closeNode } = useRoute(nodeIds);
  const { view } = route;
  const selected = pipeline.nodes.find((n) => n.id === route.node) ?? null;

  useEffect(() => {
    // Braced: `scrollTo` returns a promise in some browsers, and an effect may only return a cleanup.
    window.scrollTo({ top: 0, behavior: "instant" });
  }, [view]);

  const sectionList = content?.doc.sections;
  const sections = useMemo(() => sectionsByPath(sectionList ?? []), [sectionList]);
  const titleOf = useCallback((id: string) => pipeline.nodes.find((n) => n.id === id)?.title, []);
  const select = useCallback((node: PipelineNode) => go({ view: "flow", node: node.id }), [go]);

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
          {VIEWS.map((v) => (
            <button key={v.id} aria-pressed={view === v.id} onClick={() => go({ view: v.id, node: null })}>
              {v.label}
            </button>
          ))}
        </nav>
        <button onClick={toggleTheme} aria-label="Toggle colour scheme">
          {theme === "dark" ? "☾" : "☀"}
        </button>
      </header>

      <main className="page">
        {view === "flow" && (
          <>
            <section className="intro">
              <h1>The parse path</h1>
              <Lede paragraphs={pipeline.overview.lede} />
              <div className="stat-row">
                <Stat value={String(pipeline.nodes.length)} label="steps" />
                <Stat value={content ? String(content.stats.sectionCount) : "—"} label="documented sections" />
                <Stat value={content ? String(experimentTotal(content)) : "—"} label="experiments with a verdict" />
                <Stat value={content ? String(content.stats.tableCount) : "—"} label="measurement tables" />
                <Stat value={content ? String(content.stats.declCount) : "—"} label="declarations indexed" />
                <Stat
                  value={(content && span(content.stats.firstRecorded, content.stats.lastRecorded)) || "—"}
                  label="the log's span"
                />
              </div>
            </section>

            <How
              overview={pipeline.overview}
              sections={sections}
              nodes={pipeline.nodes}
              stages={pipeline.stages}
            />

            <section className="chart-intro">
              <h2 className="panel-rule">The whole path, drawn</h2>
              <p>
                Each node is a step a chunk of bytes passes through; each arrow is labelled with
                what it does, or with the condition under which it is taken. Numbers appear where
                the order is real — a switch tests its arms in the order they are written.{" "}
                <span className="hover-only">
                  Hover a node to read how it reaches the things it calls; select one to open the
                  evidence under it:
                </span>
                <span className="touch-only">
                  The chart is wider than the screen, so drag it sideways. Tap a node to open the
                  evidence under it:
                </span>{" "}
                the experiments that settled its shape, the source, and the assembly.
              </p>
              <FlowLegend />
            </section>

            <FlowChart pipeline={pipeline} sections={sections} selected={selected} onSelect={select} />

            <Why overview={pipeline.overview} sections={sections} nodes={pipeline.nodes} />

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
        {view === "graveyard" && <Graveyard sections={sectionList ?? []} />}
        {view === "payloads" && <Payloads sections={sectionList ?? []} />}
      </main>

      {selected && (
        <DetailPanel
          key={selected.id}
          node={selected}
          sections={sections}
          traces={traces}
          titleOf={titleOf}
          onClose={closeNode}
        />
      )}
    </>
  );
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
        <LegendLine />
        always runs, or runs on the labelled condition
      </span>
      <span>
        <LegendLine dash="5 4" />
        returns
      </span>
      <span>
        <LegendLine dash="1.5 3.5" />
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

function LegendLine({ dash }: { dash?: string }) {
  return (
    <svg width="30" height="8" aria-hidden="true">
      <line x1="0" y1="4" x2="30" y2="4" stroke="var(--text-muted)" strokeWidth="1.5" strokeDasharray={dash} />
    </svg>
  );
}
