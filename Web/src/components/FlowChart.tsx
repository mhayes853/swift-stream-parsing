import { useLayoutEffect, useMemo, useRef, useState } from "react";
import type { DocSection, EdgeKind, Pipeline, PipelineEdge, PipelineNode } from "../types";
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

// Only the vertical measurements are fixed. Everything horizontal is derived from the width the
// container actually has (see `layout`), because a hard-coded width is a promise the page cannot
// keep: at 202px per node the chart overflowed and scrolled sideways, and narrowing the constants
// until it fit at one viewport just moved the overflow to the next one.
const NODE_H = 66;
const ROW_GAP = 104; // Deep enough that a vertical edge has room for its label at the midpoint.
const PAD = 16;
const COL_GAP = 20;
const RAIL_GAP = 18;

/** Floors below which shrinking stops being legible and the chart scrolls sideways instead. */
const MIN_NODE_W = 146;
const MAX_NODE_W = 210;
const MIN_RAIL_W = 250;
const MAX_RAIL_W = 320;
// Wide enough for the longest single word in a stage title -- `dispatcher` and `Whitespace` are ten
// characters at 12.5px and cannot be wrapped, so anything narrower paints them under the first node.
const MIN_LANE_W = 112;
const MAX_LANE_W = 132;

function clamp(value: number, low: number, high: number): number {
  return Math.min(Math.max(value, low), high);
}

/**
 * Horizontal geometry for a given amount of room.
 *
 * The rail is taken off the top, since the card has to go somewhere that is not on top of the node
 * it describes; what is left pays for the lane gutter and then splits between the columns. The
 * node width is the only slack in the system, so it absorbs the difference and the chart fits.
 */
function layoutFor(available: number, columns: number) {
  // Rounded: a fractional node width puts every rect edge and centred label on a half pixel.
  const railW = Math.round(clamp(available * 0.26, MIN_RAIL_W, MAX_RAIL_W));
  const laneW = Math.round(clamp((available - railW) * 0.13, MIN_LANE_W, MAX_LANE_W));
  const forColumns = available - railW - laneW - PAD * 2;
  const nodeW = Math.floor(clamp((forColumns + COL_GAP) / columns - COL_GAP, MIN_NODE_W, MAX_NODE_W));
  const content = columns * (nodeW + COL_GAP) - COL_GAP;
  const graphWidth = laneW + content + PAD * 2;
  return { nodeW, laneW, railW, content, graphWidth, width: graphWidth + railW };
}
// Row 0's same-row arcs rise above their nodes like every other row's, so the first row needs
// headroom the others get for free from the row above.
const TOP = 52;

interface Placed {
  node: PipelineNode;
  row: number;
  cx: number;
  cy: number;
  landed: number;
  rejected: number;
}

interface Edge {
  id: string;
  from: Placed;
  to: Placed;
  spec: PipelineEdge;
  /** 1-based position, or null when the node makes no ordering claim. */
  ordinal: number | null;
  back: boolean;
  d: string;
  cp: Curve;
  /** Where the label ended up, after the de-collision pass. */
  mx: number;
  my: number;
}

type Point = [number, number];
type Curve = [Point, Point, Point, Point];

/** Cubic bezier at t. Used to slide a label along its own edge when it collides with another. */
function at([p0, p1, p2, p3]: Curve, t: number): Point {
  const u = 1 - t;
  const a = u * u * u;
  const b = 3 * u * u * t;
  const c = 3 * u * t * t;
  const d = t * t * t;
  return [
    a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
    a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1]
  ];
}

/**
 * Greedy wrap to at most `maxLines`.
 *
 * Anything past the last line is appended to it rather than dropped: a silently truncated label is
 * worse than one that runs a little wide, and `Strings and escapes` losing its third word looked
 * exactly like a rendering bug.
 */
function wrap(text: string, perLine = 26, maxLines = 2): string[] {
  const words = text.split(" ");
  const lines: string[] = [];
  let line = "";
  for (const word of words) {
    if (line && (line + " " + word).length > perLine && lines.length < maxLines - 1) {
      lines.push(line);
      line = word;
    } else {
      line = line ? line + " " + word : word;
    }
  }
  if (line) lines.push(line);
  return lines;
}

/** SVG `<text>` has nowhere to put a `<code>` span, so the drawn form just drops the marks. */
function plain(text: string): string {
  return text.replace(/`/g, "");
}

const DASH: Record<EdgeKind, string | undefined> = {
  step: undefined,
  branch: undefined,
  return: "5 4",
  detail: "1.5 3.5"
};

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
  // The card's height is content-dependent and only known after layout; it is measured back up to
  // here because the leader line has to start at an edge of the real box.
  const [cardHeight, setCardHeight] = useState(0);
  // The usable width inside `.flow-scroll`, padding excluded. Read from the element rather than
  // assumed: the container carries 24px of padding each side, which is exactly the overflow the
  // fixed layout used to produce.
  const scrollRef = useRef<HTMLDivElement>(null);
  const [available, setAvailable] = useState(1100);
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const measure = () => {
      const style = getComputedStyle(el);
      const inner =
        el.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
      if (inner > 0) setAvailable(inner);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  const { placed, byId, width, height, graphWidth, geo, rows } = useMemo(() => {
    const rows = pipeline.stages.map((stage) => ({
      stage,
      nodes: pipeline.nodes.filter((n) => n.stage === stage.id)
    }));
    const widest = Math.max(...rows.map((r) => r.nodes.length));
    const geo = layoutFor(available, widest);
    const { nodeW: NODE_W, laneW: LANE_W, content, graphWidth, width } = geo;
    const height = rows.length * (NODE_H + ROW_GAP) + TOP + PAD;

    const placed: Placed[] = [];
    rows.forEach((row, rowIndex) => {
      const rowWidth = row.nodes.length * (NODE_W + COL_GAP) - COL_GAP;
      const startX = LANE_W + PAD + (content - rowWidth) / 2;
      row.nodes.forEach((node, i) => {
        const docs = node.evidence.doc
          .map((p) => sections.get(p))
          .filter((s): s is DocSection => !!s);
        placed.push({
          node,
          row: rowIndex,
          cx: startX + i * (NODE_W + COL_GAP) + NODE_W / 2,
          cy: TOP + rowIndex * (NODE_H + ROW_GAP) + NODE_H / 2,
          landed: docs.filter((d) => d.verdict === "landed").length,
          rejected: docs.filter((d) => d.verdict === "rejected" || d.verdict === "mixed").length
        });
      });
    });

    const byId = new Map(placed.map((p) => [p.node.id, p]));
    return { placed, byId, width, height, graphWidth, geo, rows };
  }, [pipeline, sections, available]);

  const edges = useMemo(() => {
    const out: Edge[] = [];
    for (const p of placed) {
      const numbered = p.node.ordering === "ordered" && p.node.next.length > 1;
      p.node.next.forEach((spec, i) => {
        const to = byId.get(spec.to);
        if (!to) return;
        const cp = route(p, to, geo.nodeW);
        const [mx, my] = at(cp, 0.5);
        out.push({
          id: `${p.node.id}->${spec.to}`,
          from: p,
          to,
          spec,
          ordinal: numbered ? i + 1 : null,
          back: to.row < p.row,
          d: `M ${cp[0][0]} ${cp[0][1]} C ${cp[1][0]} ${cp[1][1]}, ${cp[2][0]} ${cp[2][1]}, ${cp[3][0]} ${cp[3][1]}`,
          cp,
          mx,
          my: my + 4
        });
      });
    }
    placeLabels(out, placed, geo.nodeW);
    return out;
  }, [placed, byId, geo]);

  // Widths the render body reads directly. Wrap points are derived from the box they have to fit
  // in rather than fixed: at a narrow layout `The dispatcher` used to run out under the first node
  // and get painted over by it, which reads as a truncated label.
  const NODE_W = geo.nodeW;
  const titleChars = Math.max(12, Math.floor((geo.nodeW - 26) / 6.7));
  const laneChars = Math.max(8, Math.floor((geo.laneW - 34) / 7.2));

  // An edge is lit when either end is the node under the cursor or the open one.
  const active = hovered ?? selected?.id ?? null;
  const activeNode = active ? byId.get(active) : undefined;

  // The card is pinned in the rail and slid vertically to face its node, clamped so it stays on
  // the canvas. `.flow-scroll` clips vertically, so a card taller than the room below its node
  // would otherwise lose its last entries off the bottom.
  const card = useMemo(() => {
    if (!activeNode || activeNode.node.next.length === 0) return null;
    const left = graphWidth + RAIL_GAP;
    const cardWidth = geo.railW - RAIL_GAP * 2;
    const h = cardHeight || NODE_H;
    const top = Math.min(Math.max(8, activeNode.cy - h / 2), Math.max(8, height - h - 8));
    return { left, top, width: cardWidth, height: h };
  }, [activeNode, cardHeight, graphWidth, geo, height]);
  const neighbours = useMemo(() => {
    if (!active) return new Set<string>();
    const set = new Set<string>([active]);
    for (const e of edges) {
      if (e.from.node.id === active) set.add(e.to.node.id);
      if (e.to.node.id === active) set.add(e.from.node.id);
    }
    return set;
  }, [active, edges]);

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

          {rows.map((row, i) => {
            const y = TOP + i * (NODE_H + ROW_GAP);
            return (
              <g key={row.stage.id}>
                <line
                  x1={geo.laneW + PAD - 12}
                  y1={y - ROW_GAP / 2 + NODE_H / 2}
                  x2={graphWidth - PAD}
                  y2={y - ROW_GAP / 2 + NODE_H / 2}
                  stroke="var(--grid)"
                  strokeWidth={1}
                />
                <text x={PAD} y={y + 18} className="flow-lane-index">
                  {String(i + 1).padStart(2, "0")}
                </text>
                {wrap(row.stage.title, laneChars, 3).map((line, j) => (
                  <text key={j} x={PAD + 26} y={y + 18 + j * 15} className="flow-lane-title">
                    {line}
                  </text>
                ))}
              </g>
            );
          })}

          {edges.map((edge) => {
            const lit = !!active && (edge.from.node.id === active || edge.to.node.id === active);
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

          {/* Labels sit above the edges so a crossing line never runs through the text. The halo
              is a stroke behind the glyphs rather than a rect, so nothing has to guess the width. */}
          {edges.map((edge) => {
            const lit = !!active && (edge.from.node.id === active || edge.to.node.id === active);
            return (
              <g
                key={edge.id}
                opacity={active ? (lit ? 1 : 0.14) : 0.72}
                className={`flow-edge-label${lit ? " lit" : ""}`}
              >
                {/* Halo first, then the same glyphs on top. The two must match exactly -- the
                    ordinal's tspan is mono and bold, so a plain-string halo measures narrower and
                    a centred pair renders as doubled text. */}
                {[true, false].map((halo) => (
                  <text
                    key={String(halo)}
                    x={edge.mx}
                    y={edge.my}
                    textAnchor="middle"
                    className={halo ? "halo" : undefined}
                  >
                    {edge.ordinal !== null && <tspan className="ord">{edge.ordinal} · </tspan>}
                    {plain(edge.spec.label)}
                  </text>
                ))}
              </g>
            );
          })}

          {placed.map((p) => {
            const isSelected = selected?.id === p.node.id;
            const dimmed = !!active && !neighbours.has(p.node.id);
            const titleLines = wrap(p.node.title, titleChars);
            return (
              <g
                key={p.node.id}
                className="flow-node"
                opacity={dimmed ? 0.45 : 1}
                tabIndex={0}
                role="button"
                aria-label={`${p.node.title} — ${p.node.kicker}`}
                onClick={() => onSelect(p.node)}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    onSelect(p.node);
                  }
                }}
                onMouseEnter={() => setHovered(p.node.id)}
                onMouseLeave={() => setHovered(null)}
                onFocus={() => setHovered(p.node.id)}
                onBlur={() => setHovered(null)}
              >
                <rect
                  x={p.cx - NODE_W / 2}
                  y={p.cy - NODE_H / 2}
                  width={NODE_W}
                  height={NODE_H}
                  rx={8}
                  fill="var(--surface-1)"
                  stroke={isSelected ? "var(--series-1)" : "var(--grid)"}
                  strokeWidth={isSelected ? 2 : 1}
                />
                {titleLines.map((line, i) => (
                  <text
                    key={i}
                    x={p.cx - NODE_W / 2 + 12}
                    y={p.cy - NODE_H / 2 + 21 + i * 15}
                    className="flow-node-title"
                  >
                    {line}
                  </text>
                ))}
                <text
                  x={p.cx - NODE_W / 2 + 12}
                  y={p.cy + NODE_H / 2 - 11}
                  className="flow-node-kicker"
                >
                  {p.node.kicker}
                </text>

                {p.node.viz && (
                  <text x={p.cx + NODE_W / 2 - 12} y={p.cy - NODE_H / 2 + 20} className="flow-node-viz">
                    ▶
                  </text>
                )}
                {/* Counts are written, not colour-coded alone. */}
                <text x={p.cx + NODE_W / 2 - 12} y={p.cy + NODE_H / 2 - 11} className="flow-node-counts">
                  {p.landed > 0 && <tspan className="landed">{p.landed}↑ </tspan>}
                  {p.rejected > 0 && <tspan className="rejected">{p.rejected}✕</tspan>}
                </text>
              </g>
            );
          })}
          {card && activeNode && (
            <g className="flow-leader" aria-hidden="true">
              <path
                d={leader(activeNode, card.left, card.top + 26, geo.nodeW)}
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
            placed={activeNode}
            byId={byId}
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

/**
 * What the node does with the arrows leaving it. The chart can show that `parseDispatching` reaches
 * four functions; only this can say that it reaches exactly one of them per iteration, and on what.
 */
function CallCard({
  placed,
  byId,
  left,
  top,
  width,
  onMeasure
}: {
  placed: Placed;
  byId: Map<string, Placed>;
  left: number;
  top: number;
  width: number;
  onMeasure: (height: number) => void;
}) {
  const node = placed.node;
  const numbered = node.ordering === "ordered" && node.next.length > 1;
  const ref = useRef<HTMLDivElement>(null);

  // Report the rendered height so the parent can face the card at its node and draw the leader to
  // a real edge. Measured every render because the content changes with the node.
  useLayoutEffect(() => {
    if (ref.current) onMeasure(ref.current.offsetHeight);
  });

  return (
    <div ref={ref} className="flow-card" style={{ left, top, width }}>
      <h4>{node.title}</h4>
      {node.invokes && <p className="flow-card-invokes">{inline(node.invokes, "inv")}</p>}
      <p className="flow-card-rule">
        {node.next.length === 1
          ? "Reaches one node:"
          : numbered
            ? `${node.next.length} arrows, in the order the source runs or tests them:`
            : `${node.next.length} arrows, in no particular order:`}
      </p>
      <ol className="flow-card-edges">
        {node.next.map((edge, i) => {
          const target = byId.get(edge.to);
          return (
            <li key={edge.to}>
              <span className={`flow-card-marker kind-${edge.kind}`}>
                {numbered ? i + 1 : KIND_GLYPH[edge.kind]}
              </span>
              <div>
                <p className="flow-card-head">
                  <span className="flow-card-label">{inline(edge.label, `l-${i}`)}</span>
                  <span className="flow-card-arrow"> → </span>
                  <span className="flow-card-target">{target?.node.title ?? edge.to}</span>
                </p>
                {edge.when && (
                  <p>
                    <span className={`flow-card-kind kind-${edge.kind}`}>{KIND_WORD[edge.kind]}</span>
                    {inline(edge.when, `w-${i}`)}
                  </p>
                )}
              </div>
            </li>
          );
        })}
      </ol>
    </div>
  );
}

/**
 * The dashed line from the card back to the node it describes.
 *
 * It leaves the card's left edge and enters the node on whichever side faces the rail, bowing
 * horizontally so it reads as an annotation crossing the chart rather than as another edge in it.
 */
function leader(node: Placed, cardLeft: number, cardY: number, NODE_W: number): string {
  const x1 = cardLeft;
  const y1 = cardY;
  const x2 = node.cx + NODE_W / 2;
  const y2 = node.cy;
  const bend = Math.max(28, (x1 - x2) * 0.4);
  return `M ${x1} ${y1} C ${x1 - bend} ${y1}, ${x2 + bend} ${y2}, ${x2} ${y2}`;
}

const KIND_WORD: Record<EdgeKind, string> = {
  step: "always",
  branch: "only if",
  return: "returns",
  detail: "detail"
};

const KIND_GLYPH: Record<EdgeKind, string> = {
  step: "→",
  branch: "◆",
  return: "↩",
  detail: "·"
};

/**
 * Edge routing.
 *
 * Down a row: a vertical bezier between the facing edges. Along a row: a shallow arc between the
 * near sides. Back up a row: out to the left and around so a return path is never mistaken for
 * forward progress.
 */
function route(a: Placed, b: Placed, NODE_W: number): Curve {
  const ax = a.cx;
  const bx = b.cx;

  if (b.row > a.row) {
    const y1 = a.cy + NODE_H / 2;
    const y2 = b.cy - NODE_H / 2;
    const dy = Math.max((y2 - y1) / 2, 18);
    return [
      [ax, y1],
      [ax, y1 + dy],
      [bx, y2 - dy],
      [bx, y2]
    ];
  }

  if (b.row === a.row) {
    const forward = bx > ax;
    const x1 = ax + (forward ? NODE_W / 2 : -NODE_W / 2);
    const x2 = bx + (forward ? -NODE_W / 2 : NODE_W / 2);
    // The apex has to clear the top of the node by enough to seat a label; for a cubic with both
    // controls at `cy - lift` the apex is at `cy - 0.75 * lift`, hence the division. At lift 30 the
    // arc cut straight across the boxes it was passing over.
    const lift = (NODE_H / 2 + 24) / 0.75;
    return [
      [x1, a.cy],
      [x1 + (forward ? 22 : -22), a.cy - lift],
      [x2 + (forward ? -22 : 22), b.cy - lift],
      [x2, b.cy]
    ];
  }

  // Backwards: leave and re-enter on the left, bowing further out the more rows it spans.
  const bow = 34 + (a.row - b.row) * 26;
  const x1 = ax - NODE_W / 2;
  const x2 = bx - NODE_W / 2;
  return [
    [x1, a.cy],
    [x1 - bow, a.cy],
    [x2 - bow, b.cy],
    [x2, b.cy]
  ];
}

/**
 * Keep the labels legible.
 *
 * A label wants the midpoint of its own edge, but edges converge -- three arrows into
 * `parseDispatching` put their midpoints within a few pixels of each other, and the three labels
 * land on top of one another. So each is tried at the midpoint first and then slid along its own
 * curve, with a vertical nudge as the last resort. Sliding is preferred over nudging because a
 * label that has moved along its edge is still unambiguously *that* edge's label.
 *
 * Text is measured by character count rather than by `getBBox`, since this runs during layout with
 * nothing in the DOM yet. 5.4px per character at 10.5px is an over-estimate for this font, which is
 * the safe direction to be wrong in.
 */
function placeLabels(edges: Edge[], nodes: Placed[], NODE_W: number): void {
  const H = 13;
  // Seeded with the node boxes: a label over a node title is worse than a label off its midpoint.
  const taken = nodes.map((n) => ({ x: n.cx, y: n.cy, w: NODE_W, h: NODE_H }));
  const hits = (x: number, y: number, w: number) =>
    taken.some(
      (t) =>
        Math.abs(x - t.x) * 2 < w + t.w + 6 && Math.abs(y - t.y) * 2 < H + t.h + 4
    );

  const TS = [0.5, 0.38, 0.62, 0.28, 0.72];
  const DYS = [0, -15, 15, -30, 30, -46, 46, -62, 62];

  for (const edge of edges) {
    const text = plain(
      edge.ordinal !== null ? `${edge.ordinal} · ${edge.spec.label}` : edge.spec.label
    );
    const w = text.length * 5.4 + 6;
    let best: [number, number] | null = null;
    outer: for (const dy of DYS) {
      for (const t of TS) {
        const [x, y] = at(edge.cp, t);
        if (!hits(x, y + 4 + dy, w)) {
          best = [x, y + 4 + dy];
          break outer;
        }
      }
    }
    // Nothing free: leave it at the midpoint rather than flinging it somewhere unrelated.
    const [x, y] = best ?? [edge.mx, edge.my];
    edge.mx = x;
    edge.my = y;
    taken.push({ x, y, w, h: H });
  }
}
