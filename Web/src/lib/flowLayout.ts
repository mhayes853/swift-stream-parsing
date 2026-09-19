import type { DocSection, Pipeline, PipelineEdge, PipelineNode, PipelineStage } from "../types";
import { nodeTally } from "./evidence";
import type { Curve } from "./graph";
import { at, clamp, pathOf, placeLabels, plain, route } from "./graph";

export const NODE_H = 66;
const ROW_GAP = 104;
export const PAD = 16;
const COL_GAP = 20;
const RAIL_GAP = 18;
export const TOP = 52;

const MIN_NODE_W = 146;
const MAX_NODE_W = 210;
const MIN_RAIL_W = 250;
const MAX_RAIL_W = 320;
const MIN_LANE_W = 112;
const MAX_LANE_W = 132;

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
  ordinal: number | null;
  d: string;
  cp: Curve;
  text: string;
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

export function rowRuleY(row: { y: number }): number {
  return row.y - ROW_GAP / 2 + NODE_H / 2;
}

export function cardBox(node: PlacedNode, cardHeight: number, layout: FlowLayout) {
  const h = cardHeight || NODE_H;
  return {
    left: layout.geo.graphWidth + RAIL_GAP,
    top: Math.min(Math.max(8, node.cy - h / 2), Math.max(8, layout.height - h - 8)),
    width: layout.geo.railW - RAIL_GAP * 2,
    height: h
  };
}

export function leaderPath(node: PlacedNode, cardLeft: number, cardY: number, nodeW: number): string {
  const x2 = node.cx + nodeW / 2;
  const bend = Math.max(28, (cardLeft - x2) * 0.4);
  return `M ${cardLeft} ${cardY} C ${cardLeft - bend} ${cardY}, ${x2 + bend} ${node.cy}, ${x2} ${node.cy}`;
}
