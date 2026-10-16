import type { ChunkCutTrace, Delivery, Guarantee, LibraryBundle, TestCase, TestsContent } from "../types";

export interface ResolvedGuarantee {
  guarantee: Guarantee;
  /** The cited tests, in the order the content file lists them. */
  tests: TestCase[];
  /** Tests in the files the guarantee cites, the cited ones included. */
  related: number;
}

/** A cited key's test case, or `undefined` for a helper or a suite, which are not tests. */
export function caseFor(bundle: LibraryBundle, key: string): TestCase | undefined {
  return bundle.tests.cases.find((c) => c.key === key);
}

export function fileOf(key: string): string {
  return key.slice(0, key.indexOf(":"));
}

export function nameOf(key: string): string {
  return key.slice(key.indexOf(":") + 1);
}

export function resolveGuarantee(bundle: LibraryBundle, guarantee: Guarantee): ResolvedGuarantee {
  const tests = guarantee.tests.flatMap((key) => {
    const found = caseFor(bundle, key);
    return found ? [found] : [];
  });
  const files = new Set([...guarantee.tests, ...guarantee.suites].map(fileOf));
  const related = bundle.tests.cases.filter((c) => files.has(c.key.slice(0, c.key.indexOf(":")))).length;
  return { guarantee, tests, related };
}

export function testTotals(bundle: LibraryBundle): { tests: number; parameterized: number; files: number } {
  return bundle.tests.targets.reduce(
    (sum, t) => ({
      tests: sum.tests + t.tests,
      parameterized: sum.parameterized + t.parameterized,
      files: sum.files + t.files
    }),
    { tests: 0, parameterized: 0, files: 0 }
  );
}

/** The techniques a guarantee uses, resolved to their entries. */
export function techniquesOf(content: TestsContent, guarantee: Guarantee) {
  return guarantee.technique.flatMap((id) => content.techniques.filter((t) => t.id === id));
}

// MARK: - Chunk cuts

export interface CutSummary {
  at: number;
  head: number;
  tail: number;
  both: number;
  /** The token the cut runs through, when one does. */
  straddling?: number;
}

/**
 * What one cut does to the tokens. The straddling token is the first one not delivered wholly by
 * the first call -- the one whose bytes the cut runs through, or the one it lands just before.
 */
export function cutSummary(trace: ChunkCutTrace, split: number): CutSummary {
  const delivery = trace.splits[split].delivery;
  const count = (d: Delivery) => delivery.filter((x) => x === d).length;
  const firstNotHead = delivery.findIndex((d) => d !== "head");
  return {
    at: trace.splits[split].at,
    head: count("head"),
    tail: count("tail"),
    both: count("both"),
    straddling: firstNotHead === -1 ? undefined : firstNotHead
  };
}

/** Splits where a token's content arrived in both calls: the ones only a streamed string can do. */
export function splitsWithSharedTokens(trace: ChunkCutTrace): number[] {
  return trace.splits.flatMap((s, i) => (s.delivery.includes("both") ? [i] : []));
}
