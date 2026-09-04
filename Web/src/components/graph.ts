// Geometry shared by the two charts on this site: the pipeline graph on the page, and the
// algorithm graph inside every detail panel.
//
// They draw the same language deliberately — same four edge kinds, same dashing, same rule that
// an arrow carries its label — because they are the same claim at two scales: which functions
// reach which, and what one function does. Sharing the routing is what keeps them from drifting
// into two dialects.

import type { EdgeKind } from "../types";

export type Point = [number, number];
export type Curve = [Point, Point, Point, Point];

export function clamp(value: number, low: number, high: number): number {
  return Math.min(Math.max(value, low), high);
}

/** Cubic bezier at t. Used to slide a label along its own edge when it collides with another. */
export function at([p0, p1, p2, p3]: Curve, t: number): Point {
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
export function wrap(text: string, perLine = 26, maxLines = 2): string[] {
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
export function plain(text: string): string {
  return text.replace(/`/g, "");
}

export const DASH: Record<EdgeKind, string | undefined> = {
  step: undefined,
  branch: undefined,
  return: "5 4",
  detail: "1.5 3.5"
};

export const KIND_WORD: Record<EdgeKind, string> = {
  step: "always",
  branch: "only if",
  return: "returns",
  detail: "detail"
};

export const KIND_GLYPH: Record<EdgeKind, string> = {
  step: "→",
  branch: "◆",
  return: "↩",
  detail: "·"
};

export interface Box {
  cx: number;
  cy: number;
  row: number;
}

/**
 * Edge routing.
 *
 * Down a row: a vertical bezier between the facing edges. Along a row: a shallow arc between the
 * near sides. Back up a row: out to the left and around so a return path is never mistaken for
 * forward progress.
 *
 * `spread` separates back edges that would otherwise be drawn on top of each other. Two returns
 * between the same pair of rows produce identical curves, and a loop body with three exits back to
 * its head is exactly the shape the algorithm charts are full of.
 */
export function route(
  a: Box,
  b: Box,
  nodeW: number,
  nodeH: number,
  spread = 0
): Curve {
  const ax = a.cx;
  const bx = b.cx;

  if (b.row > a.row) {
    const y1 = a.cy + nodeH / 2;
    const y2 = b.cy - nodeH / 2;
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
    const x1 = ax + (forward ? nodeW / 2 : -nodeW / 2);
    const x2 = bx + (forward ? -nodeW / 2 : nodeW / 2);
    // The apex has to clear the top of the node by enough to seat a label; for a cubic with both
    // controls at `cy - lift` the apex is at `cy - 0.75 * lift`, hence the division. At lift 30 the
    // arc cut straight across the boxes it was passing over.
    const lift = (nodeH / 2 + 24 + spread * 14) / 0.75;
    return [
      [x1, a.cy],
      [x1 + (forward ? 22 : -22), a.cy - lift],
      [x2 + (forward ? -22 : 22), b.cy - lift],
      [x2, b.cy]
    ];
  }

  // Backwards: leave and re-enter on the left, bowing further out the more rows it spans.
  const bow = 34 + (a.row - b.row) * 26 + spread * 20;
  const x1 = ax - nodeW / 2;
  const x2 = bx - nodeW / 2;
  return [
    [x1, a.cy],
    [x1 - bow, a.cy],
    [x2 - bow, b.cy],
    [x2, b.cy]
  ];
}

export interface Labelled {
  cp: Curve;
  text: string;
  mx: number;
  my: number;
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
export function placeLabels(
  edges: Labelled[],
  nodes: Box[],
  nodeW: number,
  nodeH: number,
  perChar = 5.4
): void {
  const H = 13;
  // Seeded with the node boxes: a label over a node title is worse than a label off its midpoint.
  const taken = nodes.map((n) => ({ x: n.cx, y: n.cy, w: nodeW, h: nodeH }));
  const hits = (x: number, y: number, w: number) =>
    taken.some(
      (t) => Math.abs(x - t.x) * 2 < w + t.w + 6 && Math.abs(y - t.y) * 2 < H + t.h + 4
    );

  const TS = [0.5, 0.38, 0.62, 0.28, 0.72];
  const DYS = [0, -15, 15, -30, 30, -46, 46, -62, 62];

  for (const edge of edges) {
    const w = edge.text.length * perChar + 6;
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

/**
 * Row assignment for a graph that has loops in it.
 *
 * Every one of these kernels is a loop, so a plain longest-path rank does not terminate. The back
 * edges are found first, by DFS from the entry -- an edge into a step already on the stack is one --
 * and the rank is the longest path over what is left. That puts a loop's head above its body, which
 * is what makes the returning arrow read as a return.
 */
export function rankGraph(
  ids: string[],
  next: (id: string) => string[]
): Map<string, number> {
  const back = new Set<string>();
  const onStack = new Set<string>();
  const done = new Set<string>();

  const visit = (id: string) => {
    onStack.add(id);
    for (const to of next(id)) {
      if (onStack.has(to)) {
        back.add(`${id}->${to}`);
      } else if (!done.has(to)) {
        visit(to);
      }
    }
    onStack.delete(id);
    done.add(id);
  };
  visit(ids[0]);
  // A step the entry cannot reach is a build error, but the chart still has to draw something.
  for (const id of ids) if (!done.has(id)) visit(id);

  const rank = new Map<string, number>(ids.map((id) => [id, 0]));
  // Longest path by relaxation. Bounded by the step count because the graph is acyclic once the
  // back edges are out.
  for (let pass = 0; pass < ids.length; pass += 1) {
    let moved = false;
    for (const id of ids) {
      for (const to of next(id)) {
        if (back.has(`${id}->${to}`)) continue;
        const candidate = (rank.get(id) ?? 0) + 1;
        if (candidate > (rank.get(to) ?? 0)) {
          rank.set(to, candidate);
          moved = true;
        }
      }
    }
    if (!moved) break;
  }
  return rank;
}
