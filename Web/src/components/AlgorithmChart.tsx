import { useMemo, useState } from "react";
import {
  KICKER_PER_CHAR,
  KICKER_SIZE,
  NODE_H,
  TEXT_INSET,
  TITLE_PER_CHAR,
  TITLE_SIZE,
  fit,
  layoutAlgorithm
} from "../lib/algorithmLayout";
import { DASH, neighbours } from "../lib/graph";
import type { AlgorithmStep, PipelineNode, SourceDecl } from "../types";
import { EdgeLabel } from "./EdgeLabel";
import { EdgeList } from "./EdgeList";
import { useInnerWidth } from "./hooks";
import { inline } from "./Markdown";

// The same chart as the page's, one scale down: the pipeline graph says which functions reach
// which, and this says what one of them does. Every node has one, because a step whose branches
// are not written down is exactly the step somebody re-derives from the assembly later.
//
// It is the same drawing language on purpose — `step`, `branch`, `return`, `detail`, every arrow
// carrying its label, ordered fan-outs numbered — so that moving between the two charts does not
// mean learning a second notation. The layout is in `lib/algorithmLayout.ts`.
//
// State is per node: the panel keys this by node id, so a different node starts at its entry.

export function AlgorithmChart({
  node,
  decls
}: {
  node: PipelineNode;
  /** Resolved declarations, so a step can say where its source is without a second fetch. */
  decls: Record<string, SourceDecl[]> | null;
}) {
  const [selected, setSelected] = useState<string | null>(null);
  const [hovered, setHovered] = useState<string | null>(null);
  const [scrollRef, available] = useInnerWidth<HTMLDivElement>(600);
  const { placed, geo, height, edges, view, scale } = useMemo(
    () => layoutAlgorithm(node, available),
    [node, available]
  );

  // The entry step is the default reading, so opening a panel already says something.
  const entry = node.steps[0];
  const open = selected ?? entry.id;
  const active = hovered ?? open;
  const detail = node.steps.find((s) => s.id === open) ?? entry;
  const near = useMemo(
    () => neighbours(active, edges.map((e) => [e.from.step.id, e.to.step.id])),
    [active, edges]
  );

  return (
    <section className="algo">
      <header className="algo-head">
        <h3>Inside this step</h3>
        <p>
          {node.steps.length} steps, {edges.length} arrows. Select one to read what it does.
        </p>
      </header>
      <div className="algo-scroll" ref={scrollRef}>
        <svg
          className="algo-svg"
          width={view.width * scale}
          height={height * scale}
          viewBox={`${view.left} 0 ${view.width} ${height}`}
          role="img"
          aria-label={`Control flow inside ${node.title}. Select a step to read what it does.`}
        >
          <defs>
            <marker id="a-arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto">
              <path d="M0,0 L8,4 L0,8 z" fill="var(--text-muted)" />
            </marker>
            <marker id="a-arrow-lit" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto">
              <path d="M0,0 L8,4 L0,8 z" fill="var(--series-1)" />
            </marker>
          </defs>

          {edges.map((edge) => {
            const lit = edge.from.step.id === active || edge.to.step.id === active;
            return (
              <path
                key={edge.id}
                d={edge.d}
                fill="none"
                stroke={lit ? "var(--series-1)" : "var(--text-muted)"}
                strokeWidth={lit ? 1.8 : 1.1}
                strokeDasharray={DASH[edge.kind]}
                opacity={lit ? 1 : 0.28}
                markerEnd={lit ? "url(#a-arrow-lit)" : "url(#a-arrow)"}
              />
            );
          })}

          {edges.map((edge) => {
            const lit = edge.from.step.id === active || edge.to.step.id === active;
            return (
              <EdgeLabel
                key={edge.id}
                x={edge.mx}
                y={edge.my}
                label={edge.label}
                ordinal={edge.ordinal}
                lit={lit}
                opacity={lit ? 1 : 0.2}
                className="algo-edge-label"
              />
            );
          })}

          {placed.map((p) => {
            const isOpen = p.step.id === open;
            const title = fit(p.step.title, geo.nodeW, TITLE_SIZE, TITLE_PER_CHAR, 2);
            const kicker = p.step.kicker
              ? fit(p.step.kicker, geo.nodeW, KICKER_SIZE, KICKER_PER_CHAR, 1)
              : null;
            const isEntry = p.step.id === entry.id;
            const isExit = p.step.next.length === 0;
            const left = p.cx - geo.nodeW / 2;
            const top = p.cy - NODE_H / 2;
            return (
              <g
                key={p.step.id}
                className="algo-node"
                opacity={near.has(p.step.id) ? 1 : 0.42}
                tabIndex={0}
                role="button"
                aria-label={`${p.step.title}${p.step.kicker ? ` — ${p.step.kicker}` : ""}`}
                aria-pressed={isOpen}
                onClick={() => setSelected(p.step.id)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    setSelected(p.step.id);
                  }
                }}
                onMouseEnter={() => setHovered(p.step.id)}
                onMouseLeave={() => setHovered(null)}
                onFocus={() => setHovered(p.step.id)}
                onBlur={() => setHovered(null)}
              >
                <rect
                  x={left}
                  y={top}
                  width={geo.nodeW}
                  height={NODE_H}
                  rx={7}
                  fill="var(--surface-1)"
                  stroke={isOpen ? "var(--series-1)" : "var(--grid)"}
                  strokeWidth={isOpen ? 2 : 1}
                />
                {/* The entry and the exits are marked, because "where does this start" and "how
                    does it get out" are the two questions a loop drawing has to answer. */}
                {(isEntry || isExit) && (
                  <rect
                    x={left}
                    y={top + (isEntry ? 0 : NODE_H - 3)}
                    width={geo.nodeW}
                    height={3}
                    rx={1.5}
                    fill={isEntry ? "var(--series-1)" : "var(--text-muted)"}
                    opacity={isEntry ? 0.8 : 0.5}
                  />
                )}
                {title.lines.map((line, i) => (
                  <text
                    key={i}
                    x={left + TEXT_INSET}
                    y={top + 19 + i * 14}
                    className="algo-node-title"
                    style={{ fontSize: title.size }}
                  >
                    {line}
                  </text>
                ))}
                {kicker && (
                  <text
                    x={left + TEXT_INSET}
                    y={p.cy + NODE_H / 2 - 10}
                    className="algo-node-kicker"
                    style={{ fontSize: kicker.size }}
                  >
                    {kicker.lines[0]}
                  </text>
                )}
              </g>
            );
          })}
        </svg>
      </div>

      <StepCard step={detail} node={node} decls={decls} isEntry={detail.id === entry.id} />
    </section>
  );
}

/** What the selected step does, what it cites, and what leaves it. */
function StepCard({
  step,
  node,
  decls,
  isEntry
}: {
  step: AlgorithmStep;
  node: PipelineNode;
  decls: Record<string, SourceDecl[]> | null;
  isEntry: boolean;
}) {
  const decl = step.source ? decls?.[step.source]?.[0] : undefined;
  const [file, symbol] = step.source?.split(":") ?? [];

  return (
    <div className="algo-card">
      <div className="algo-card-head">
        <h4>{inline(step.title, "t")}</h4>
        {isEntry && <span className="algo-tag entry">entry</span>}
        {step.next.length === 0 && <span className="algo-tag exit">ends here</span>}
        {step.kicker && <span className="algo-tag">{inline(step.kicker, "k")}</span>}
      </div>
      <p className="algo-card-detail">{inline(step.detail, "d")}</p>
      {step.source && (
        <p className="algo-card-source">
          <code>{symbol}</code>
          <span>{decl ? `${decl.file}:${decl.startLine}` : file} · in the Source tab</span>
        </p>
      )}
      {step.next.length > 0 && (
        <EdgeList
          edges={step.next}
          ordered={step.ordering === "ordered"}
          titleOf={(id) => node.steps.find((s) => s.id === id)?.title}
          single="Leads to one step:"
        />
      )}
    </div>
  );
}
