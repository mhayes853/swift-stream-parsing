import type { DocSection, Measurement } from "../types";

// Every signed delta the log records, grouped by the payload it was measured on.

const NAMES: Record<string, string> = {
  canada: "canada.json",
  twitter: "twitter.json",
  twitterescaped: "twitterescaped.json",
  citm_catalog: "citm_catalog.json",
  "gsoc-2018": "gsoc-2018.json",
  github_events: "github_events.json",
  llm_message: "llm_message.json",
  mesh: "mesh",
  qwen: "Qwen 3 tool call",
  pretty_printed: "pretty printed",
  matrix: "Payloads.matrix",
  unicode_escapes: "unicode escapes"
};

/** The name a payload goes by in the benchmarks, or its id where there is no better one. */
export function payloadName(id: string): string {
  return NAMES[id] ?? id;
}

export interface DeltaRow extends Measurement {
  section: DocSection;
}

export function deltaRows(sections: DocSection[]): DeltaRow[] {
  return sections.flatMap((section) =>
    section.measurements.filter((m) => m.isDelta).map((m) => ({ ...m, section }))
  );
}

/** Payloads by how many deltas they carry, most first. */
export function payloadCounts(rows: DeltaRow[]): [id: string, count: number][] {
  const counts = new Map<string, number>();
  for (const r of rows) counts.set(r.payload, (counts.get(r.payload) ?? 0) + 1);
  return [...counts.entries()].sort((a, b) => b[1] - a[1]);
}

/** One payload's deltas, largest gain first. */
export function rowsFor(rows: DeltaRow[], payload: string): DeltaRow[] {
  return rows.filter((r) => r.payload === payload).sort((a, b) => b.value - a.value);
}

/**
 * A diverging bar, as percentages of its track: a gain and a loss are opposite polarities around a
 * true zero at the middle, and the largest magnitude on screen reaches the edge.
 */
export function divergingBar(value: number, extent: number): { left: number; width: number; positive: boolean } {
  const positive = value >= 0;
  const width = (Math.abs(value) / Math.max(1, extent)) * 50;
  return { positive, width, left: positive ? 50 : 50 - width };
}
