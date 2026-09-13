import { describe, expect, it } from "vitest";
import { content, history, pipeline, section, sources } from "../test/fixtures";
import type { PipelineNode } from "../types";
import {
  byVerdictThenAge,
  declLanguage,
  declWhere,
  experimentTotal,
  listingSummary,
  nodeEvidence,
  nodeTally,
  repoURL,
  sectionWhere,
  sectionsByPath,
  verdictCounts
} from "./evidence";

const landed = section({ title: "Landed: a", verdict: "landed", history: history("2026-08-03T10:00:00Z") });
const rejectedLate = section({ title: "Rejected: b", verdict: "rejected", history: history("2026-08-09T10:00:00Z") });
const rejectedEarly = section({ title: "Rejected: c", verdict: "rejected", history: history("2026-08-01T10:00:00Z") });
const mixed = section({ title: "Mixed: d", verdict: "mixed" });
const context = section({ title: "How it works" });
const byPath = sectionsByPath([landed, rejectedLate, rejectedEarly, mixed, context]);

const node = {
  evidence: { doc: [landed.path, "missing/path", context.path, rejectedLate.path, mixed.path], source: [], asm: [] }
} as unknown as PipelineNode;

describe("nodeEvidence", () => {
  it("splits a node's sections into experiments and explanations, dropping what does not resolve", () => {
    const { experiments, explanations } = nodeEvidence(node, byPath);
    expect(experiments.map((s) => s.title)).toEqual(["Landed: a", "Rejected: b", "Mixed: d"]);
    expect(explanations.map((s) => s.title)).toEqual(["How it works"]);
  });

  it("resolves every reference in the real pipeline", () => {
    // The extractor fails the build on a dangling doc slug; this is the same promise, kept by the
    // bundle the site actually loads.
    const all = sectionsByPath(content.doc.sections);
    for (const n of pipeline.nodes) {
      const { experiments, explanations } = nodeEvidence(n, all);
      expect(experiments.length + explanations.length, n.id).toBe(n.evidence.doc.length);
    }
  });
});

describe("byVerdictThenAge", () => {
  it("puts rejections first, then mixed, then landed, oldest first within each", () => {
    expect(byVerdictThenAge([landed, rejectedLate, mixed, rejectedEarly]).map((s) => s.title)).toEqual([
      "Rejected: c",
      "Rejected: b",
      "Mixed: d",
      "Landed: a"
    ]);
  });
});

describe("tallies", () => {
  it("counts every verdict", () => {
    expect(verdictCounts([landed, rejectedLate, rejectedEarly, context])).toEqual({
      landed: 1,
      rejected: 2,
      mixed: 0,
      neutral: 1
    });
  });

  it("counts a mixed result as not landed on the chart", () => {
    expect(nodeTally(node, byPath)).toEqual({ landed: 1, rejected: 2 });
  });

  it("totals the log's experiments, ignoring the sections that explain", () => {
    const counts = content.stats.verdictCounts;
    expect(experimentTotal(content)).toBe((counts.landed ?? 0) + (counts.rejected ?? 0) + (counts.mixed ?? 0));
  });
});

describe("locations", () => {
  it("says where a section is, and how many tables it has", () => {
    expect(sectionWhere({ ...context, line: 12, tables: [] })).toBe("NEW_ARCHITECTURE.md:12");
    expect(sectionWhere({ ...landed, chapter: "Numbers", line: 40, tables: [{ headers: [], rows: [] }] })).toBe(
      "NEW_ARCHITECTURE.md:40 · Numbers · 1 table"
    );
  });

  it("says where a declaration is, with its attributes", () => {
    const decl = Object.values(sources.sources).flat()[0];
    expect(declWhere({ ...decl, file: "A.swift", startLine: 3, endLine: 9, attributes: [] })).toBe("A.swift:3–9");
    expect(declWhere({ ...decl, file: "A.swift", startLine: 3, endLine: 9, attributes: ["@inline(__always)"] })).toBe(
      "A.swift:3–9 · @inline(__always)"
    );
  });

  it("highlights the shim's declarations as C and everything else as Swift", () => {
    const decl = Object.values(sources.sources).flat()[0];
    expect(declLanguage({ ...decl, kind: "c-function" })).toBe("c");
    expect(declLanguage({ ...decl, kind: "func" })).toBe("swift");
  });

  it("links to a file, a line, or a range", () => {
    const repo = "https://github.com/mhayes853/swift-stream-parsing/blob/main";
    expect(repoURL("A.swift")).toBe(`${repo}/A.swift`);
    expect(repoURL("A.swift", 3)).toBe(`${repo}/A.swift#L3`);
    expect(repoURL("A.swift", 3, 9)).toBe(`${repo}/A.swift#L3-L9`);
  });

  it("reads the instruction count out of a listing's header", () => {
    expect(listingSummary("; parse\n; 812 instructions, 3 blocks\n100: ret")).toBe("812 instructions, 3 blocks");
    expect(listingSummary("100: ret")).toBeUndefined();
    expect(listingSummary(undefined)).toBeUndefined();
  });
});
