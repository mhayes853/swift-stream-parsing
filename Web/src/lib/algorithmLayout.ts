import type { AlgorithmStep, EdgeKind, PipelineNode } from "../types";
import type { Box, Curve } from "./graph";
import { at, clamp, pathOf, placeLabels, plain, rankGraph, route, wrap } from "./graph";

export const NODE_H = 56;
const ROW_GAP = 76;
const TOP = 44;

const MIN_NODE_W = 104;
const MAX_NODE_W = 168;
const MAX_COL_GAP = 14;
const MIN_COL_GAP = 9;
const PAD = 8;

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

export const TITLE_PER_CHAR = 6.62;
export const KICKER_PER_CHAR = 4.91;
const LABEL_PER_CHAR = 4.9;
export const TITLE_SIZE = 11;
export const KICKER_SIZE = 9.5;
export const TEXT_INSET = 10;

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
  if (maxLines === 2 && longest(lines) > perLine) lines = balanced(plain(text));
  const widest = Math.max(longest(lines), 1) * perChar;
  return { lines, size: widest <= room ? size : Math.max(7.5, (size * room) / widest) };
}

function longest(lines: string[]): number {
  return Math.max(0, ...lines.map((l) => l.length));
}

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
  view: { left: number; width: number };
  scale: number;
}

export function layoutAlgorithm(node: PipelineNode, available: number): AlgorithmLayout {
  const first = build(node, available);
  const overhang = first.right - first.left - available;
  const fitted = overhang > 0 ? build(node, available - overhang) : first;
  const width = fitted.right - fitted.left;
  const scale = width > available && available / width >= 0.88 ? available / width : 1;
  return { ...fitted, view: { left: fitted.left, width }, scale };
}
