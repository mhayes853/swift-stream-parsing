import type { DocSection, Pipeline, PipelineEdge, PipelineNode, PipelineStage } from "../types";
import { nodeTally } from "./evidence";
import type { Curve } from "./graph";
import { at, clamp, pathOf, placeLabels, plain, route } from "./graph";

// Layout for the page chart: the parse path, one row per stage, with a rail to the right that the
// hover card lives in.
//
// Only the vertical measurements are fixed. Everything horizontal is derived from the width the
// container actually has, because a hard-coded width is a promise the page cannot keep: at 202px
// per node the chart overflowed and scrolled sideways, and narrowing the constants until it fit at
// one viewport just moved the overflow to the next one.

export const NODE_H = 66;
const ROW_GAP = 104; // Deep enough that a vertical edge has room for its label at the midpoint.
export const PAD = 16;
const COL_GAP = 20;
const RAIL_GAP = 18;
// Row 0's same-row arcs rise above their nodes like every other row's, so the first row needs
// headroom the others get for free from the row above.
export const TOP = 52;

/** Floors below which shrinking stops being legible and the chart scrolls sideways instead. */
const MIN_NODE_W = 146;
const MAX_NODE_W = 210;
const MIN_RAIL_W = 250;
const MAX_RAIL_W = 320;
// Wide enough for the longest single word in a stage title -- `dispatcher` and `Whitespace` are ten
// characters at 12.5px and cannot be wrapped, so anything narrower paints them under the first node.
const MIN_LANE_W = 112;
const MAX_LANE_W = 132;

/**
 * Horizontal geometry for a given amount of room.
 *
 * The rail is taken off the top, since the card has to go somewhere that is not on top of the node
 * it describes; what is left pays for the lane gutter and then splits between the columns. The
 * node width is the only slack in the system, so it absorbs the difference and the chart fits.
 * With no hover there is no card to put in the rail, and on a phone its 250px were a third of the
 * sideways scroll.
 */
export function layoutFor(available: number, columns: number, rail: boolean) {
  // Rounded: a fractional node width puts every rect edge and centred label on a half pixel.
  const railW = rail ? Math.round(clamp(available * 0.26, MIN_RAIL_W, MAX_RAIL_W)) : 0;
  const laneW = Math.round(clamp((available - railW) * 0.13, MIN_LANE_W, MAX_LANE_W));
  const forColumns = available - railW - laneW - PAD * 2;
  const nodeW = Math.floor(clamp((forColumns + COL_GAP) / columns - COL_GAP, MIN_NODE_W, MAX_NODE_W));
  const content = columns * (nodeW + COL_GAP) - COL_GAP;
  const graphWidth = laneW + content + PAD * 2;
  return { nodeW, laneW, railW, content, graphWidth, width: graphWidth + railW };
}

export interface PlacedNode {
  node: PipelineNode;
  row: number;
  cx: number;
  cy: number;
  landed: number;
  rejected: number;
}

export interface FlowEdge {
  id: string;
  from: PlacedNode;
  to: PlacedNode;
  spec: PipelineEdge;
  /** 1-based position, or null when the node makes no ordering claim. */
  ordinal: number | null;
  d: string;
  cp: Curve;
  /** The drawn form, measured by `placeLabels` before anything is in the DOM. */
  text: string;
  /** Where the label ended up, after the de-collision pass. */
  mx: number;
  my: number;
}

export interface FlowLayout {
  rows: { stage: PipelineStage; nodes: PipelineNode[]; y: number }[];
  placed: PlacedNode[];
  byId: Map<string, PlacedNode>;
  edges: FlowEdge[];
  geo: ReturnType<typeof layoutFor>;
  width: number;
  height: number;
  /** Characters per line in a node title and a stage title. Derived from the box they have to fit
   *  in rather than fixed: at a narrow layout `The dispatcher` used to run out under the first node
   *  and get painted over by it, which reads as a truncated label. */
  titleChars: number;
  laneChars: number;
}

export function layoutFlow(
  pipeline: Pipeline,
  sections: Map<string, DocSection>,
  available: number,
  rail: boolean
): FlowLayout {
  const stages = pipeline.stages.map((stage, i) => ({
    stage,
    nodes: pipeline.nodes.filter((n) => n.stage === stage.id),
    y: TOP + i * (NODE_H + ROW_GAP)
  }));
  const geo = layoutFor(available, Math.max(...stages.map((r) => r.nodes.length)), rail);

  const placed = stages.flatMap((row, rowIndex) => {
    const rowWidth = row.nodes.length * (geo.nodeW + COL_GAP) - COL_GAP;
    const startX = geo.laneW + PAD + (geo.content - rowWidth) / 2;
    return row.nodes.map((node, i) => ({
      node,
      row: rowIndex,
      cx: startX + i * (geo.nodeW + COL_GAP) + geo.nodeW / 2,
      cy: row.y + NODE_H / 2,
      ...nodeTally(node, sections)
    }));
  });
  const byId = new Map(placed.map((p) => [p.node.id, p]));

  const edges: FlowEdge[] = placed.flatMap((p) => {
    const numbered = p.node.ordering === "ordered" && p.node.next.length > 1;
    return p.node.next.flatMap((spec, i) => {
      const to = byId.get(spec.to);
      if (!to) return [];
      const cp = route(p, to, geo.nodeW, NODE_H);
      const [mx, my] = at(cp, 0.5);
      const ordinal = numbered ? i + 1 : null;
      return [{
        id: `${p.node.id}->${spec.to}`,
        from: p,
        to,
        spec,
        ordinal,
        d: pathOf(cp),
        cp,
        text: plain(ordinal !== null ? `${ordinal} · ${spec.label}` : spec.label),
        mx,
        my: my + 4
      }];
    });
  });
  placeLabels(edges, placed, geo.nodeW, NODE_H);

  return {
    rows: stages,
    placed,
    byId,
    edges,
    geo,
    width: geo.width,
    height: stages.length * (NODE_H + ROW_GAP) + TOP + PAD,
    titleChars: Math.max(12, Math.floor((geo.nodeW - 26) / 6.7)),
    laneChars: Math.max(8, Math.floor((geo.laneW - 34) / 7.2))
  };
}

/** Where a row's separator runs: halfway through the gap above the row. */
export function rowRuleY(row: { y: number }): number {
  return row.y - ROW_GAP / 2 + NODE_H / 2;
}

/**
 * The hover card's box: pinned in the rail and slid vertically to face its node, clamped so it
 * stays on the canvas. `.flow-scroll` clips vertically, so a card taller than the room below its
 * node would otherwise lose its last entries off the bottom.
 */
export function cardBox(node: PlacedNode, cardHeight: number, layout: FlowLayout) {
  const h = cardHeight || NODE_H;
  return {
    left: layout.geo.graphWidth + RAIL_GAP,
    top: Math.min(Math.max(8, node.cy - h / 2), Math.max(8, layout.height - h - 8)),
    width: layout.geo.railW - RAIL_GAP * 2,
    height: h
  };
}

/**
 * The dashed line from the card back to the node it describes.
 *
 * It leaves the card's left edge and enters the node on the side that faces the rail, bowing
 * horizontally so it reads as an annotation crossing the chart rather than as another edge in it.
 */
export function leaderPath(node: PlacedNode, cardLeft: number, cardY: number, nodeW: number): string {
  const x2 = node.cx + nodeW / 2;
  const bend = Math.max(28, (cardLeft - x2) * 0.4);
  return `M ${cardLeft} ${cardY} C ${cardLeft - bend} ${cardY}, ${x2 + bend} ${node.cy}, ${x2} ${node.cy}`;
}
