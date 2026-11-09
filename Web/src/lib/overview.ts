import type { DocSection, OverviewItem, PipelineNode, PipelineStage } from "../types";
import { repoURL } from "./evidence";
import { formatRoute } from "./route";

function list(value: string | string[] | undefined): string[] {
  return value === undefined ? [] : typeof value === "string" ? [value] : value;
}

export function paragraphs(item: OverviewItem): string[] {
  return list(item.detail);
}

/**
 * The chart lanes a step is drawn in, in the order the chart draws them.
 *
 * These are not links: a lane is part of the page already, so the citation scrolls to it rather
 * than navigating, and a stage the chart no longer has is dropped the way a doc slug would be.
 */
export function lanes(item: OverviewItem, stages: readonly PipelineStage[]): PipelineStage[] {
  const wanted = list(item.stage);
  return stages.filter((stage) => wanted.includes(stage.id));
}

export interface OverviewCitation {
  kind: "node" | "doc";
  /** A node id for `node`, a doc slug for `doc`. */
  id: string;
  label: string;
  /** Where the citation goes: a hash route for a node, the repository for a section. */
  href: string;
}

/**
 * The evidence under an overview card, resolved to what a link can be drawn from.
 *
 * A section that has not loaded yet, or one whose slug the extractor would have rejected, is
 * dropped rather than drawn as a dead link — the build is where a dangling citation is caught,
 * and the page still renders while content.json is in flight.
 */
export function citations(
  item: OverviewItem,
  sections: Map<string, DocSection>,
  nodes: readonly PipelineNode[]
): OverviewCitation[] {
  const out: OverviewCitation[] = [];
  for (const id of list(item.node)) {
    const node = nodes.find((n) => n.id === id);
    if (node) {
      out.push({
        kind: "node",
        id: node.id,
        label: node.title,
        href: formatRoute({ view: "flow", node: node.id })
      });
    }
  }
  for (const slug of item.doc ?? []) {
    const section = sections.get(slug);
    if (section) {
      out.push({
        kind: "doc",
        id: slug,
        label: section.title,
        href: repoURL("NEW_ARCHITECTURE.md", section.line)
      });
    }
  }
  return out;
}
