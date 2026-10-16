import type { ContentBundle, DocSection, PipelineNode, SourceDecl, Verdict } from "../types";
import { instant } from "./dates";

export function sectionsByPath(sections: DocSection[]): Map<string, DocSection> {
  return new Map(sections.map((s) => [s.path, s]));
}

export function isExperiment(section: DocSection): boolean {
  return section.verdict !== "neutral";
}

export interface NodeEvidence {
  experiments: DocSection[];
  explanations: DocSection[];
}

export function nodeEvidence(node: PipelineNode, sections: Map<string, DocSection>): NodeEvidence {
  const docs = node.evidence.doc.map((path) => sections.get(path)).filter((s): s is DocSection => !!s);
  return {
    experiments: docs.filter(isExperiment),
    explanations: docs.filter((s) => !isExperiment(s))
  };
}

const VERDICT_ORDER: Record<Verdict, number> = { rejected: 0, mixed: 1, landed: 2, neutral: 3 };

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

export function nodeTally(node: PipelineNode, sections: Map<string, DocSection>) {
  const counts = verdictCounts(nodeEvidence(node, sections).experiments);
  return { landed: counts.landed, rejected: counts.rejected + counts.mixed };
}

export function experimentTotal(content: ContentBundle): number {
  const v = content.stats.verdictCounts;
  return (v.landed ?? 0) + (v.rejected ?? 0) + (v.mixed ?? 0);
}

const REPO = "https://github.com/mhayes853/swift-stream-parsing/blob/main";

export function repoURL(path: string, from?: number, to?: number): string {
  const anchor = from === undefined ? "" : to === undefined ? `#L${from}` : `#L${from}-L${to}`;
  return `${REPO}/${path}${anchor}`;
}

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

export function declWhere(decl: SourceDecl): string {
  const range = `${decl.file}:${decl.startLine}–${decl.endLine}`;
  return decl.attributes.length > 0 ? `${range} · ${decl.attributes.join(" ")}` : range;
}

export function declLanguage(decl: SourceDecl): "c" | "swift" {
  return decl.kind.startsWith("c-") ? "c" : "swift";
}

export function listingSummary(listing: string | undefined): string | undefined {
  return listing
    ?.split("\n")
    .find((line) => line.startsWith(";") && line.includes("instructions"))
    ?.replace("; ", "");
}
