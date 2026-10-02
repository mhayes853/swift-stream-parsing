import { describe, expect, it } from "vitest";
import { library, testsContent, traces } from "../test/fixtures";
import { caseFor, cutSummary, resolveGuarantee, splitsWithSharedTokens, techniquesOf, testTotals } from "./tests";

describe("guarantees", () => {
  it("resolve every cited test to a case in the index", () => {
    for (const guarantee of testsContent.guarantees) {
      const resolved = resolveGuarantee(library, guarantee);
      expect(resolved.tests.map((t) => t.key)).toEqual(guarantee.tests);
      expect(resolved.related).toBeGreaterThanOrEqual(resolved.tests.length);
    }
  });

  it("carry the body of every showcase and suite they cite", () => {
    for (const guarantee of testsContent.guarantees) {
      for (const key of [guarantee.showcase, ...guarantee.suites]) expect(library.decls[key]?.code).toBeTruthy();
    }
  });

  it("name techniques the content file defines", () => {
    for (const guarantee of testsContent.guarantees) {
      expect(techniquesOf(testsContent, guarantee).length).toBe(guarantee.technique.length);
    }
  });

  it("treat a helper as a citation rather than a test", () => {
    expect(caseFor(library, "ChunkBoundary.swift:expectChunkBoundaryEquivalence")).toBeUndefined();
  });

  it("count the whole index", () => {
    const totals = testTotals(library);
    expect(totals.tests).toBe(library.tests.cases.length);
    expect(totals.parameterized).toBe(library.tests.cases.filter((c) => c.parameterized).length);
  });
});

describe("chunk cuts", () => {
  const trace = traces.chunkCuts;

  it("covers every split and verified against the whole parse", () => {
    expect(trace.verified).toBe(true);
    expect(trace.splits.map((s) => s.at)).toEqual(trace.bytes.slice(1).map((_, i) => i + 1));
    for (const split of trace.splits) expect(split.delivery.length).toBe(trace.tokens.length);
  });

  it("moves tokens from the second call to the first as the cut moves right", () => {
    const heads = trace.splits.map((_, i) => cutSummary(trace, i).head);
    for (let i = 1; i < heads.length; i++) expect(heads[i]).toBeGreaterThanOrEqual(heads[i - 1]);
  });

  it("shares a token between both calls only when it is a string", () => {
    const shared = splitsWithSharedTokens(trace);
    expect(shared.length).toBeGreaterThan(0);
    for (const i of shared) {
      trace.splits[i].delivery.forEach((d, t) => {
        if (d === "both") expect(trace.tokens[t].kind).toBe("string");
      });
    }
  });
});
