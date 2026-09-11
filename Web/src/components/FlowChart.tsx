import { useLayoutEffect, useMemo, useRef, useState } from "react";
import { NODE_H, PAD, cardBox, layoutFlow, leaderPath, rowRuleY } from "../lib/flowLayout";
import type { PlacedNode } from "../lib/flowLayout";
import { DASH, neighbours, wrap } from "../lib/graph";
import type { DocSection, Pipeline, PipelineNode } from "../types";
import { EdgeLabel } from "./EdgeLabel";
import { EdgeList } from "./EdgeList";
import { useInnerWidth, useMediaQuery } from "./hooks";
import { inline } from "./Markdown";

// A directed graph of the parse path, laid out in stage rows. The edges are `next` in
// pipeline.json -- the real control flow, including the ones that go backwards: the whitespace
// scan returns to the structural run, which calls it again before the next structural byte.
//
// Every arrow carries its label, because an unlabelled arrow between two functions says only that
// one reaches the other, which is the least interesting thing about it. `dispatcher` has four, and
// the four are not steps: they are the arms of a `switch` on `self.state`, exactly one of which
// runs per iteration. That distinction is `kind`, and it is drawn -- branches get their condition,
// a `return` is dashed, a `detail` is dotted. Where the order is real (a switch's arms are tested
// in the order they are written) `ordering` is `ordered` and the arrows are numbered.
//
// The layout is in `lib/flowLayout.ts`; this draws it.

export function FlowChart({
  pipeline,
  sections,
  selected,
  onSelect
}: {
  pipeline: Pipeline;
  sections: Map<string, DocSection>;
  selected: PipelineNode | null;
  onSelect: (node: PipelineNode) => void;
}) {
  const [hovered, setHovered] = useState<string | null>(null);
  // The call card opens on hover, and a touch screen has none to open it with: a tap fires the
  // emulated `mouseenter` and then the click that opens the panel over it, so the card would only
  // ever be seen for a frame. Without hover there is no card, and no rail reserved for one.
  const canHover = useMediaQuery("(hover: hover)");
  // The card's height is content-dependent and only known after layout; it is measured back up to
  // here because the leader line has to start at an edge of the real box.
  const [cardHeight, setCardHeight] = useState(0);
  const [scrollRef, available] = useInnerWidth<HTMLDivElement>(1100);

  const layout = useMemo(
    () => layoutFlow(pipeline, sections, available, canHover),
    [pipeline, sections, available, canHover]
  );
  const { placed, byId, edges, geo, width, height } = layout;
  const nodeW = geo.nodeW;

  // An edge is lit when either end is the node under the cursor or the open one.
  const active = hovered ?? selected?.id ?? null;
  const activeNode = active ? byId.get(active) : undefined;
  const card =
    canHover && activeNode && activeNode.node.next.length > 0
      ? cardBox(activeNode, cardHeight, layout)
      : null;
  const near = useMemo(
    () => neighbours(active, edges.map((e) => [e.from.node.id, e.to.node.id])),
    [active, edges]
  );
  const isLit = (edge: (typeof edges)[number]) =>
    !!active && (edge.from.node.id === active || edge.to.node.id === active);

  return (
    <div className="flow-scroll" ref={scrollRef}>
      <div className="flow-stage" style={{ width, height }}>
        <svg
          className="flow"
          width={width}
          height={height}
          viewBox={`0 0 ${width} ${height}`}
          role="img"
          aria-label="Flow chart of the parse path. Select a step to open its evidence."
        >
          <defs>
            <marker id="arrow" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto">
              <path d="M0,0 L8,4 L0,8 z" fill="var(--text-muted)" />
            </marker>
            <marker id="arrow-lit" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="7" markerHeight="7" orient="auto">
              <path d="M0,0 L8,4 L0,8 z" fill="var(--series-1)" />
            </marker>
            <marker id="arrow-leader" viewBox="0 0 8 8" refX="7" refY="4" markerWidth="6" markerHeight="6" orient="auto">
              <path d="M0,0 L8,4 L0,8 z" fill="var(--series-1)" opacity="0.5" />
            </marker>
          </defs>

          {layout.rows.map((row, i) => (
            <g key={row.stage.id}>
              <line
                x1={geo.laneW + PAD - 12}
                y1={rowRuleY(row)}
                x2={geo.graphWidth - PAD}
                y2={rowRuleY(row)}
                stroke="var(--grid)"
                strokeWidth={1}
              />
              <text x={PAD} y={row.y + 18} className="flow-lane-index">
                {String(i + 1).padStart(2, "0")}
              </text>
              {wrap(row.stage.title, layout.laneChars, 3).map((line, j) => (
                <text key={j} x={PAD + 26} y={row.y + 18 + j * 15} className="flow-lane-title">
                  {line}
                </text>
              ))}
            </g>
          ))}

          {edges.map((edge) => {
            const lit = isLit(edge);
            return (
              <path
                key={edge.id}
                d={edge.d}
                fill="none"
                stroke={lit ? "var(--series-1)" : "var(--text-muted)"}
                strokeWidth={lit ? 2 : 1.25}
                strokeDasharray={DASH[edge.spec.kind]}
                opacity={active ? (lit ? 1 : 0.22) : 0.6}
                markerEnd={lit ? "url(#arrow-lit)" : "url(#arrow)"}
              />
            );
          })}

          {edges.map((edge) => {
            const lit = isLit(edge);
            return (
              <EdgeLabel
                key={edge.id}
                x={edge.mx}
                y={edge.my}
                label={edge.spec.label}
                ordinal={edge.ordinal}
                lit={lit}
                opacity={active ? (lit ? 1 : 0.14) : 0.72}
              />
            );
          })}

          {placed.map((p) => (
            <FlowNode
              key={p.node.id}
              placed={p}
              nodeW={nodeW}
              titleChars={layout.titleChars}
              selected={selected?.id === p.node.id}
              dimmed={!!active && !near.has(p.node.id)}
              onSelect={() => onSelect(p.node)}
              onHover={(on) => setHovered(on ? p.node.id : null)}
            />
          ))}

          {card && activeNode && (
            <g className="flow-leader" aria-hidden="true">
              <path
                d={leaderPath(activeNode, card.left, card.top + 26, nodeW)}
                fill="none"
                stroke="var(--series-1)"
                strokeWidth={1.5}
                strokeDasharray="4 4"
                opacity={0.5}
                markerEnd="url(#arrow-leader)"
              />
            </g>
          )}
        </svg>

        {card && activeNode && (
          <CallCard
            node={activeNode.node}
            titleOf={(id) => byId.get(id)?.node.title}
            left={card.left}
            top={card.top}
            width={card.width}
            onMeasure={setCardHeight}
          />
        )}
      </div>
    </div>
  );
}

function FlowNode({
  placed: p,
  nodeW,
  titleChars,
  selected,
  dimmed,
  onSelect,
  onHover
}: {
  placed: PlacedNode;
  nodeW: number;
  titleChars: number;
  selected: boolean;
  dimmed: boolean;
  onSelect: () => void;
  onHover: (on: boolean) => void;
}) {
  const left = p.cx - nodeW / 2;
  const right = p.cx + nodeW / 2;
  const top = p.cy - NODE_H / 2;
  const bottom = p.cy + NODE_H / 2;
  return (
    <g
      className="flow-node"
      opacity={dimmed ? 0.45 : 1}
      tabIndex={0}
      role="button"
      aria-label={`${p.node.title} — ${p.node.kicker}`}
      onClick={onSelect}
      onKeyDown={(e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          onSelect();
        }
      }}
      onMouseEnter={() => onHover(true)}
      onMouseLeave={() => onHover(false)}
      onFocus={() => onHover(true)}
      onBlur={() => onHover(false)}
    >
      <rect
        x={left}
        y={top}
        width={nodeW}
        height={NODE_H}
        rx={8}
        fill="var(--surface-1)"
        stroke={selected ? "var(--series-1)" : "var(--grid)"}
        strokeWidth={selected ? 2 : 1}
      />
      {wrap(p.node.title, titleChars).map((line, i) => (
        <text key={i} x={left + 12} y={top + 21 + i * 15} className="flow-node-title">
          {line}
        </text>
      ))}
      <text x={left + 12} y={bottom - 11} className="flow-node-kicker">
        {p.node.kicker}
      </text>

      {p.node.viz && (
        <text x={right - 12} y={top + 20} className="flow-node-viz">
          ▶
        </text>
      )}
      {/* Counts are written, not colour-coded alone. */}
      <text x={right - 12} y={bottom - 11} className="flow-node-counts">
        {p.landed > 0 && <tspan className="landed">{p.landed}↑ </tspan>}
        {p.rejected > 0 && <tspan className="rejected">{p.rejected}✕</tspan>}
      </text>
    </g>
  );
}

/**
 * What the node does with the arrows leaving it. The chart can show that `parseDispatching` reaches
 * four functions; only this can say that it reaches exactly one of them per iteration, and on what.
 */
function CallCard({
  node,
  titleOf,
  left,
  top,
  width,
  onMeasure
}: {
  node: PipelineNode;
  titleOf: (id: string) => string | undefined;
  left: number;
  top: number;
  width: number;
  onMeasure: (height: number) => void;
}) {
  const ref = useRef<HTMLDivElement>(null);

  // Report the rendered height so the parent can face the card at its node and draw the leader to
  // a real edge. Measured every render because the content changes with the node.
  useLayoutEffect(() => {
    if (ref.current) onMeasure(ref.current.offsetHeight);
  });

  return (
    <div ref={ref} className="flow-card" style={{ left, top, width }}>
      <h4>{node.title}</h4>
      <Reaches node={node} titleOf={titleOf} />
    </div>
  );
}

/**
 * The body of the call card, without the card. The detail panel draws it too on a touch screen,
 * where there is no hover to open the card with and no rail beside the chart to put it in.
 */
export function Reaches({
  node,
  titleOf
}: {
  node: PipelineNode;
  titleOf: (id: string) => string | undefined;
}) {
  return (
    <>
      {node.invokes && <p className="flow-card-invokes">{inline(node.invokes, "inv")}</p>}
      <EdgeList
        edges={node.next}
        ordered={node.ordering === "ordered"}
        titleOf={titleOf}
        single="Reaches one node:"
      />
    </>
  );
}
