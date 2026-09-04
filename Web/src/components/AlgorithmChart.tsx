import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AlgorithmStep, PipelineNode, SourceDecl } from "../types";
import type { Box, Curve } from "./graph";
import {
  DASH,
  KIND_GLYPH,
  KIND_WORD,
  at,
  clamp,
  placeLabels,
  plain,
  rankGraph,
  route,
  wrap
} from "./graph";
import { inline } from "./Markdown";

// The same chart as the page's, one scale down: the pipeline graph says which functions reach
// which, and this says what one of them does. Every node has one, because a step whose branches
// are not written down is exactly the step somebody re-derives from the assembly later.
//
// It is the same drawing language on purpose — `step`, `branch`, `return`, `detail`, every arrow
// carrying its label, ordered fan-outs numbered — so that moving between the two charts does not
// mean learning a second notation. What differs is the row assignment: these graphs are loops, so
// the rank comes from a DFS that finds the back edges first (`rankGraph`), which is what puts a
// loop's head above its body and makes the returning arrow read as a return.

const NODE_H = 56;
const ROW_GAP = 76;
const TOP = 44;

// Narrower than the page chart's floors: this lives in a 680px panel, and a graph five arms wide
// is the normal shape here rather than the exception — `parseDispatching`'s switch and the state
// ladder's rungs are both five, and both have to fit without the panel scrolling sideways.
const MIN_NODE_W = 104;
const MAX_NODE_W = 168;
const MAX_COL_GAP = 14;
const MIN_COL_GAP = 9;
const PAD = 8;

/**
 * Horizontal geometry for a given amount of room.
 *
 * The gap gives before the node does. `parseDispatching` and the state ladder are five arms wide,
 * which at the full gap overflowed the panel by 36px — and the node width is what carries the
 * text, so shrinking it first is the wrong order. Below `MIN_COL_GAP` the chart scrolls sideways
 * instead, because two boxes nine pixels apart stop reading as two boxes.
 */
function layoutFor(available: number, columns: number) {
  let colGap = MAX_COL_GAP;
  let nodeW = MIN_NODE_W;
  while (colGap > MIN_COL_GAP) {
    nodeW = Math.floor(
      clamp((available - PAD * 2 + colGap) / columns - colGap, MIN_NODE_W, MAX_NODE_W)
    );
    if (columns * (nodeW + colGap) - colGap + PAD * 2 <= available) break;
    colGap -= 1;
  }
  const content = columns * (nodeW + colGap) - colGap;
  return { nodeW, colGap, content, width: content + PAD * 2 };
}

// Measured off the rendered glyphs rather than guessed: the title is 11px mono and the kicker is
// 9.5px of the UI face.
const TITLE_PER_CHAR = 6.62;
const KICKER_PER_CHAR = 4.91;
// Edge labels are 9.5px of the UI face, same as the kicker.
const LABEL_PER_CHAR = 4.9;
const TITLE_SIZE = 11;
const KICKER_SIZE = 9.5;
const TEXT_INSET = 10;

/**
 * Lay a label inside a box without truncating it.
 *
 * Wrapping is tried first, but it cannot help a single identifier —
 * `StreamStringRun(end:containsNonASCII:)` has nowhere to break and ran 94px past its box. So the
 * line that does not fit is set smaller instead. That keeps the rule the rest of the site keeps:
 * a label that is a little small still says what it says, where one that is cut off looks like a
 * rendering bug and reads as a different symbol.
 */
function fit(
  text: string,
  boxWidth: number,
  size: number,
  perChar: number,
  maxLines: number
): { lines: string[]; size: number } {
  const room = boxWidth - TEXT_INSET * 2;
  const lines = wrap(plain(text), Math.max(6, Math.floor(room / perChar)), maxLines);
  const widest = Math.max(...lines.map((l) => l.length), 1) * perChar;
  // 7.5px is where mono stops being readable at this weight; below it the chart would be lying
  // about legibility rather than about width, so the label is allowed to sit a hair proud.
  return { lines, size: widest <= room ? size : Math.max(7.5, (size * room) / widest) };
  // Applied as an inline style rather than SVG's `font-size` attribute: `.algo-node-title` sets a
  // size in the stylesheet, and a presentation attribute loses to any rule that matches.
}

interface Placed extends Box {
  step: AlgorithmStep;
}

interface Edge {
  id: string;
  from: Placed;
  to: Placed;
  kind: AlgorithmStep["next"][number]["kind"];
  label: string;
  ordinal: number | null;
  d: string;
  cp: Curve;
  text: string;
  mx: number;
  my: number;
}

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

  // The entry step is the default reading, so opening a panel already says something.
  useEffect(() => setSelected(null), [node.id]);

  const scrollRef = useRef<HTMLDivElement>(null);
  const [available, setAvailable] = useState(600);
  useLayoutEffect(() => {
    const el = scrollRef.current;
    if (!el) return;
    const measure = () => {
      const style = getComputedStyle(el);
      const inner = el.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
      if (inner > 0) setAvailable(inner);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  // Laid out twice on purpose.
  //
  // A returning arrow bows out past the left of the leftmost node and its label rides the apex, so
  // how much room the drawing needs is not known until it has been routed — `the chunk after this
  // one` on the buffering graph wanted 30px that the node grid had not reserved. The first pass
  // measures that overhang and the second gives the grid that much less, which is what keeps the
  // panel from scrolling sideways over a loop-back label.
  const { placed, geo, height, edges, view } = useMemo(() => {
    const first = build(node, available);
    const overhang = first.right - first.left - available;
    const fitted = overhang > 0 ? build(node, available - overhang) : first;
    return { ...fitted, view: { left: fitted.left, width: fitted.right - fitted.left } };
  }, [node, available]);
  const edgeList = edges.list;

  // The re-fit above only helps while the node width has slack. Where it is already at the floor —
  // the buffering and skip graphs, whose loop-backs span three rows — the drawing still wants ~20px
  // more than the panel has, and the second pass just moves the nodes left by the same amount. So
  // the last 12% is taken by scaling the drawing rather than by scrolling it. Past that the chart
  // scrolls at full size instead, because a graph shrunk to half is not a graph anybody can read.
  const scale = view.width > available && available / view.width >= 0.88 ? available / view.width : 1;

  const entry = node.steps[0];
  const open = (selected ?? entry.id);
  const active = hovered ?? open;
  const detail = node.steps.find((s) => s.id === open) ?? entry;

  const neighbours = useMemo(() => {
    const set = new Set<string>([active]);
    for (const e of edgeList) {
      if (e.from.step.id === active) set.add(e.to.step.id);
      if (e.to.step.id === active) set.add(e.from.step.id);
    }
    return set;
  }, [active, edgeList]);

  return (
    <section className="algo">
      <header className="algo-head">
        <h3>Inside this step</h3>
        <p>
          {node.steps.length} steps, {edgeList.length} arrows. Select one to read what it does.
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

          {edgeList.map((edge) => {
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

          {edgeList.map((edge) => {
            const lit = edge.from.step.id === active || edge.to.step.id === active;
            return (
              <g
                key={edge.id}
                opacity={lit ? 1 : 0.2}
                className={`flow-edge-label algo-edge-label${lit ? " lit" : ""}`}
              >
                {/* Halo first, then the same glyphs on top; the two must match exactly, or a
                    centred pair renders as doubled text. */}
                {[true, false].map((halo) => (
                  <text
                    key={String(halo)}
                    x={edge.mx}
                    y={edge.my}
                    textAnchor="middle"
                    className={halo ? "halo" : undefined}
                  >
                    {edge.ordinal !== null && <tspan className="ord">{edge.ordinal} · </tspan>}
                    {plain(edge.label)}
                  </text>
                ))}
              </g>
            );
          })}

          {placed.map((p) => {
            const isOpen = p.step.id === open;
            const dimmed = !neighbours.has(p.step.id);
            const title = fit(p.step.title, geo.nodeW, TITLE_SIZE, TITLE_PER_CHAR, 2);
            const kicker = p.step.kicker
              ? fit(p.step.kicker, geo.nodeW, KICKER_SIZE, KICKER_PER_CHAR, 1)
              : null;
            const isEntry = p.step.id === entry.id;
            const isExit = p.step.next.length === 0;
            return (
              <g
                key={p.step.id}
                className="algo-node"
                opacity={dimmed ? 0.42 : 1}
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
                  x={p.cx - geo.nodeW / 2}
                  y={p.cy - NODE_H / 2}
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
                    x={p.cx - geo.nodeW / 2}
                    y={p.cy - NODE_H / 2 + (isEntry ? 0 : NODE_H - 3)}
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
                    x={p.cx - geo.nodeW / 2 + TEXT_INSET}
                    y={p.cy - NODE_H / 2 + 19 + i * 14}
                    className="algo-node-title"
                    style={{ fontSize: title.size }}
                  >
                    {line}
                  </text>
                ))}
                {kicker && (
                  <text
                    x={p.cx - geo.nodeW / 2 + TEXT_INSET}
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
  const numbered = step.ordering === "ordered" && step.next.length > 1;
  const byId = new Map(node.steps.map((s) => [s.id, s]));
  const decl = step.source ? decls?.[step.source]?.[0] : undefined;

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
          <code>{step.source.split(":")[1]}</code>
          <span>
            {decl ? `${decl.file}:${decl.startLine}` : step.source.split(":")[0]} · in the Source tab
          </span>
        </p>
      )}
      {step.next.length > 0 && (
        <>
          <p className="flow-card-rule">
            {step.next.length === 1
              ? "Leads to one step:"
              : numbered
                ? `${step.next.length} arrows, in the order the source runs or tests them:`
                : `${step.next.length} arrows, in no particular order:`}
          </p>
          <ol className="flow-card-edges">
            {step.next.map((edge, i) => (
              <li key={edge.to}>
                <span className={`flow-card-marker kind-${edge.kind}`}>
                  {numbered ? i + 1 : KIND_GLYPH[edge.kind]}
                </span>
                <div>
                  <p className="flow-card-head">
                    <span className="flow-card-label">{inline(edge.label, `l-${i}`)}</span>
                    <span className="flow-card-arrow"> → </span>
                    <span className="flow-card-target">{byId.get(edge.to)?.title ?? edge.to}</span>
                  </p>
                  {edge.when && (
                    <p>
                      <span className={`flow-card-kind kind-${edge.kind}`}>
                        {KIND_WORD[edge.kind]}
                      </span>
                      {inline(edge.when, `w-${i}`)}
                    </p>
                  )}
                </div>
              </li>
            ))}
          </ol>
        </>
      )}
    </div>
  );
}

/**
 * One pass of layout: rows from the loop-aware rank, boxes across each row, then the edges routed
 * and their labels placed. Returns the extent actually drawn, which is what the caller re-fits to.
 */
function build(node: PipelineNode, available: number) {
  const steps = node.steps;
  const ids = steps.map((s) => s.id);
  const bySpec = new Map(steps.map((s) => [s.id, s]));
  const rank = rankGraph(ids, (id) => (bySpec.get(id)?.next ?? []).map((e) => e.to));

  const rows: string[][] = [];
  for (const id of ids) {
    const r = rank.get(id) ?? 0;
    while (rows.length <= r) rows.push([]);
    rows[r].push(id);
  }
  const widest = Math.max(...rows.map((r) => r.length), 1);
  const geo = layoutFor(available, widest);

  const placed: Placed[] = [];
  rows.forEach((row, rowIndex) => {
    const rowWidth = row.length * (geo.nodeW + geo.colGap) - geo.colGap;
    const startX = PAD + (geo.content - rowWidth) / 2;
    row.forEach((id, i) => {
      placed.push({
        step: bySpec.get(id)!,
        row: rowIndex,
        cx: startX + i * (geo.nodeW + geo.colGap) + geo.nodeW / 2,
        cy: TOP + rowIndex * (NODE_H + ROW_GAP) + NODE_H / 2
      });
    });
  });
  const byId = new Map(placed.map((p) => [p.step.id, p]));

  const list: Edge[] = [];
  // Back and same-row edges between the same rows draw identical curves, so each gets its own bow.
  // A loop body with three exits back to its head is the normal shape here.
  const seen = new Map<string, number>();
  for (const p of placed) {
    const numbered = p.step.ordering === "ordered" && p.step.next.length > 1;
    p.step.next.forEach((spec, i) => {
      const to = byId.get(spec.to);
      if (!to) return;
      const key = `${Math.min(p.row, to.row)}:${Math.max(p.row, to.row)}:${
        to.row < p.row ? "b" : to.row === p.row ? "s" : "f"
      }`;
      const spread = seen.get(key) ?? 0;
      seen.set(key, spread + 1);
      const cp = route(p, to, geo.nodeW, NODE_H, to.row <= p.row ? spread : 0);
      const [mx, my] = at(cp, 0.5);
      list.push({
        id: `${p.step.id}->${spec.to}`,
        from: p,
        to,
        kind: spec.kind,
        label: spec.label,
        ordinal: numbered ? i + 1 : null,
        d: `M ${cp[0][0]} ${cp[0][1]} C ${cp[1][0]} ${cp[1][1]}, ${cp[2][0]} ${cp[2][1]}, ${cp[3][0]} ${cp[3][1]}`,
        cp,
        text: plain(numbered ? `${i + 1} · ${spec.label}` : spec.label),
        mx,
        my: my + 4
      });
    });
  }
  placeLabels(list, placed, geo.nodeW, NODE_H, LABEL_PER_CHAR);

  // The viewBox is sized to what is actually drawn rather than to the node grid.
  let left = 0;
  let right = geo.width;
  for (const edge of list) {
    const half = (edge.text.length * LABEL_PER_CHAR) / 2 + 4;
    left = Math.min(left, edge.mx - half, ...edge.cp.map((p) => p[0]));
    right = Math.max(right, edge.mx + half, ...edge.cp.map((p) => p[0]));
  }
  return {
    placed,
    geo,
    height: rows.length * (NODE_H + ROW_GAP) + TOP + PAD - ROW_GAP + 34,
    edges: { list },
    left: Math.floor(left) - 4,
    right: Math.ceil(right) + 4
  };
}
