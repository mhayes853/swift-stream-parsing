import type { AlgorithmStep, EdgeKind, PipelineNode } from "../types";
import type { Box, Curve } from "./graph";
import { at, clamp, pathOf, placeLabels, plain, rankGraph, route, wrap } from "./graph";

// Layout for the chart inside every detail panel: what one node does, as a graph of its steps.
//
// These graphs are loops, so the rows come from `rankGraph` rather than a plain longest path, and
// the layout is done twice — see `layoutAlgorithm`.

export const NODE_H = 56;
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
export function layoutFor(available: number, columns: number) {
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
export const TITLE_PER_CHAR = 6.62;
export const KICKER_PER_CHAR = 4.91;
// Edge labels are 9.5px of the UI face, same as the kicker.
const LABEL_PER_CHAR = 4.9;
export const TITLE_SIZE = 11;
export const KICKER_SIZE = 9.5;
export const TEXT_INSET = 10;

/**
 * Lay a label inside a box without truncating it.
 *
 * Wrapping is tried first, but it cannot help a single identifier —
 * `StreamStringRun(end:containsNonASCII:)` has nowhere to break and ran 94px past its box. So the
 * line that does not fit is set smaller instead. That keeps the rule the rest of the site keeps:
 * a label that is a little small still says what it says, where one that is cut off looks like a
 * rendering bug and reads as a different symbol.
 */
export function fit(
  text: string,
  boxWidth: number,
  size: number,
  perChar: number,
  maxLines: number
): { lines: string[]; size: number } {
  const room = boxWidth - TEXT_INSET * 2;
  const perLine = Math.max(6, Math.floor(room / perChar));
  let lines = wrap(plain(text), perLine, maxLines);
  // Greedy wrapping fills the first line and leaves everything else on the last, so a title too
  // long for two lines came out as one short line and one very long one -- and it is the long one
  // the size is scaled to. At the node-width floor a phone gets, `up to 64 / bytes live in the
  // value` hit the 7.5px floor and still ran 20px out of its box, where `up to 64 bytes / live in
  // the value` fits at 8.2px. Only taken when greedy has already failed, so a label that fits is
  // unchanged.
  if (maxLines === 2 && longest(lines) > perLine) lines = balanced(plain(text));
  const widest = Math.max(longest(lines), 1) * perChar;
  // 7.5px is where mono stops being readable at this weight; below it the chart would be lying
  // about legibility rather than about width, so the label is allowed to sit a hair proud.
  return { lines, size: widest <= room ? size : Math.max(7.5, (size * room) / widest) };
}

function longest(lines: string[]): number {
  return Math.max(0, ...lines.map((l) => l.length));
}

/**
 * The two-line split whose longer line is shortest: at a space where there is one, and otherwise at
 * a camel-case hump. A lone identifier has no space to break at, and `promoteSizedInlineStorage`
 * at the 7.5px floor still ran past its box; `promoteSized / InlineStorage` fits at 10.7px, and a
 * break at a hump still reads as one name.
 */
export function balanced(text: string): string[] {
  const words = text.split(" ");
  const cuts =
    words.length > 1
      ? words.slice(1).map((_, i) => words.slice(0, i + 1).join(" ").length)
      : [...text.matchAll(/[a-z)](?=[A-Z(])/g)].map((m) => m.index + 1);
  let best = [text];
  for (const cut of cuts) {
    const split = [text.slice(0, cut).trimEnd(), text.slice(cut).trimStart()];
    if (longest(split) < longest(best)) best = split;
  }
  return best;
}

export interface PlacedStep extends Box {
  step: AlgorithmStep;
}

export interface StepEdge {
  id: string;
  from: PlacedStep;
  to: PlacedStep;
  kind: EdgeKind;
  label: string;
  ordinal: number | null;
  d: string;
  cp: Curve;
  text: string;
  mx: number;
  my: number;
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

  const placed: PlacedStep[] = [];
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

  const edges: StepEdge[] = [];
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
      edges.push({
        id: `${p.step.id}->${spec.to}`,
        from: p,
        to,
        kind: spec.kind,
        label: spec.label,
        ordinal: numbered ? i + 1 : null,
        d: pathOf(cp),
        cp,
        text: plain(numbered ? `${i + 1} · ${spec.label}` : spec.label),
        mx,
        my: my + 4
      });
    });
  }
  placeLabels(edges, placed, geo.nodeW, NODE_H, LABEL_PER_CHAR);

  // The viewBox is sized to what is actually drawn rather than to the node grid.
  let left = 0;
  let right = geo.width;
  for (const edge of edges) {
    const half = (edge.text.length * LABEL_PER_CHAR) / 2 + 4;
    left = Math.min(left, edge.mx - half, ...edge.cp.map((p) => p[0]));
    right = Math.max(right, edge.mx + half, ...edge.cp.map((p) => p[0]));
  }
  return {
    placed,
    geo,
    edges,
    height: rows.length * (NODE_H + ROW_GAP) + TOP + PAD - ROW_GAP + 34,
    left: Math.floor(left) - 4,
    right: Math.ceil(right) + 4
  };
}

export interface AlgorithmLayout {
  placed: PlacedStep[];
  geo: ReturnType<typeof layoutFor>;
  edges: StepEdge[];
  height: number;
  /** The drawn extent, as a viewBox. */
  view: { left: number; width: number };
  /** Below 1 when the drawing is shrunk to fit rather than scrolled. */
  scale: number;
}

/**
 * The chart for `node` in `available` pixels.
 *
 * Laid out twice on purpose. A returning arrow bows out past the left of the leftmost node and its
 * label rides the apex, so how much room the drawing needs is not known until it has been routed —
 * `the chunk after this one` on the buffering graph wanted 30px that the node grid had not
 * reserved. The first pass measures that overhang and the second gives the grid that much less.
 *
 * The re-fit only helps while the node width has slack. Where it is already at the floor — the
 * buffering and skip graphs, whose loop-backs span three rows — the drawing still wants ~20px more
 * than the panel has, and the second pass just moves the nodes left by the same amount. So the last
 * 12% is taken by scaling the drawing rather than by scrolling it. Past that the chart scrolls at
 * full size instead, because a graph shrunk to half is not a graph anybody can read.
 */
export function layoutAlgorithm(node: PipelineNode, available: number): AlgorithmLayout {
  const first = build(node, available);
  const overhang = first.right - first.left - available;
  const fitted = overhang > 0 ? build(node, available - overhang) : first;
  const width = fitted.right - fitted.left;
  const scale = width > available && available / width >= 0.88 ? available / width : 1;
  return { ...fitted, view: { left: fitted.left, width }, scale };
}
