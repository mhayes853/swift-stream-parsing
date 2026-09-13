import type { ContentBundle, DocSection, PipelineNode, SourceDecl, Verdict } from "../types";
import { instant } from "./dates";

// How a node's evidence is read: which of its sections are experiments, in what order, and how
// many of each verdict there are. The same rules drive the node counts on the page chart, the
// panel's two tabs and the experiments view, so they live here rather than in any one of them.

export function sectionsByPath(sections: DocSection[]): Map<string, DocSection> {
  return new Map(sections.map((s) => [s.path, s]));
}

/** An experiment is a section that reached a verdict; the rest explain rather than decide. */
export function isExperiment(section: DocSection): boolean {
  return section.verdict !== "neutral";
}

export interface NodeEvidence {
  experiments: DocSection[];
  explanations: DocSection[];
}

/** A node's doc references, resolved and split. A reference that does not resolve is dropped. */
export function nodeEvidence(node: PipelineNode, sections: Map<string, DocSection>): NodeEvidence {
  const docs = node.evidence.doc.map((path) => sections.get(path)).filter((s): s is DocSection => !!s);
  return {
    experiments: docs.filter(isExperiment),
    explanations: docs.filter((s) => !isExperiment(s))
  };
}

const VERDICT_ORDER: Record<Verdict, number> = { rejected: 0, mixed: 1, landed: 2, neutral: 3 };

/**
 * Rejections first: they are the ones that stop a decision being re-litigated. Within a verdict,
 * oldest first, so a step's experiments read in the order they were actually tried.
 */
export function byVerdictThenAge(sections: DocSection[]): DocSection[] {
  return [...sections].sort(
    (a, b) =>
      VERDICT_ORDER[a.verdict] - VERDICT_ORDER[b.verdict] ||
      instant(a.history?.recorded) - instant(b.history?.recorded)
  );
}

export function verdictCounts(sections: DocSection[]): Record<Verdict, number> {
  const out: Record<Verdict, number> = { landed: 0, rejected: 0, mixed: 0, neutral: 0 };
  for (const s of sections) out[s.verdict] += 1;
  return out;
}

/** The chart's two counts on a node: what landed, and what did not (a mixed result counts as not). */
export function nodeTally(node: PipelineNode, sections: Map<string, DocSection>) {
  const counts = verdictCounts(nodeEvidence(node, sections).experiments);
  return { landed: counts.landed, rejected: counts.rejected + counts.mixed };
}

/** Every experiment the log records, for the page's headline number. */
export function experimentTotal(content: ContentBundle): number {
  const v = content.stats.verdictCounts;
  return (v.landed ?? 0) + (v.rejected ?? 0) + (v.mixed ?? 0);
}

const REPO = "https://github.com/mhayes853/swift-stream-parsing/blob/main";

/** A file in the repository on GitHub, optionally at a line or a range of lines. */
export function repoURL(path: string, from?: number, to?: number): string {
  const anchor = from === undefined ? "" : to === undefined ? `#L${from}` : `#L${from}-L${to}`;
  return `${REPO}/${path}${anchor}`;
}

/** Where a section sits in the log: `NEW_ARCHITECTURE.md:4599 · Two dispatchers… · 1 table`. */
export function sectionWhere(section: DocSection): string {
  const tables = section.tables.length;
  return [
    `NEW_ARCHITECTURE.md:${section.line}`,
    section.chapter !== section.title && section.chapter,
    tables > 0 && `${tables} table${tables === 1 ? "" : "s"}`
  ]
    .filter(Boolean)
    .join(" · ");
}

/** Where a declaration is: `Sources/…/StreamScanners.swift:318–352 · @inline(__always)`. */
export function declWhere(decl: SourceDecl): string {
  const range = `${decl.file}:${decl.startLine}–${decl.endLine}`;
  return decl.attributes.length > 0 ? `${range} · ${decl.attributes.join(" ")}` : range;
}

/** The grammar a declaration's code is highlighted with. The shim's C is the only non-Swift. */
export function declLanguage(decl: SourceDecl): "c" | "swift" {
  return decl.kind.startsWith("c-") ? "c" : "swift";
}

/** The instruction count from a pinned listing's header, as the extractor wrote it. */
export function listingSummary(listing: string | undefined): string | undefined {
  return listing
    ?.split("\n")
    .find((line) => line.startsWith(";") && line.includes("instructions"))
    ?.replace("; ", "");
}
