// Mirrors the Swift models in Sources/StreamParsingSiteTool. Everything except pipeline.json is
// generated, so if these drift the fix is in the extractor, not here.

export type Verdict = "landed" | "rejected" | "mixed" | "neutral";

export interface TableCell {
  text: string;
  bold: boolean;
  value?: number;
  unit?: string;
  isDelta: boolean;
}

export interface DocTable {
  headers: string[];
  rows: TableCell[][];
  labelColumn?: number;
}

export interface Measurement {
  payload: string;
  rowLabel: string;
  column: string;
  value: number;
  unit?: string;
  isDelta: boolean;
}

export interface DocCodeBlock {
  language: string;
  code: string;
}

export interface DocSection {
  path: string;
  slug: string;
  title: string;
  level: number;
  parentPath?: string;
  chapter: string;
  line: number;
  verdict: Verdict;
  markdown: string;
  summary: string;
  tables: DocTable[];
  codeBlocks: DocCodeBlock[];
  measurements: Measurement[];
}

export interface ContentBundle {
  generatedAt: string;
  doc: { path: string; title: string; sections: DocSection[] };
  stats: {
    sectionCount: number;
    tableCount: number;
    codeBlockCount: number;
    declCount: number;
    fileCount: number;
    verdictCounts: Record<string, number>;
  };
}

export interface SourceDecl {
  symbol: string;
  qualifiedName: string;
  kind: string;
  file: string;
  startLine: number;
  endLine: number;
  attributes: string[];
  comment?: string;
  code: string;
  members: string[];
}

export interface SourceBundle {
  generatedAt: string;
  sources: Record<string, SourceDecl[]>;
}

// MARK: - Pipeline

export interface PipelineStage {
  id: string;
  title: string;
  blurb: string;
}

export type VizKind = "stringRun" | "whitespace" | "containers" | "number";

/**
 * How to read an arrow. `step` runs unconditionally and is numbered by its position in `next`;
 * `branch` is taken only when `when` holds; `return` hands control back to a node that already
 * ran; `detail` zooms into the same work rather than moving through it.
 */
export type EdgeKind = "step" | "branch" | "return" | "detail";

export interface PipelineEdge {
  to: string;
  kind: EdgeKind;
  /** Drawn on the arrow. The extractor rejects an empty one. */
  label: string;
  /** The full circumstance, shown when the source node is hovered or open. */
  when?: string;
}

export interface PipelineNode {
  id: string;
  stage: string;
  title: string;
  kicker: string;
  prose: string[];
  viz: VizKind | null;
  evidence: { doc: string[]; source: string[]; asm: string[] };
  /** One sentence on how this node reaches what it calls. */
  invokes?: string;
  /** `ordered` means `next` is written in the order the source runs or tests them. */
  ordering?: "ordered" | "unordered";
  next: PipelineEdge[];
}

export interface Pipeline {
  version: number;
  stages: PipelineStage[];
  nodes: PipelineNode[];
}

// MARK: - Traces

export interface StringRunBlock {
  offset: number;
  bytes: number[];
  isQuote: boolean[];
  isBackslash: boolean[];
  isControl: boolean[];
  hit: boolean[];
  anyHit: boolean;
  hitLane: number;
  scannedAfter: number[];
  nonASCIIAfter: boolean;
}

export interface StringRunTrace {
  sample: string;
  bytes: number[];
  blocks: StringRunBlock[];
  tail: { offset: number; byte: number; terminates: boolean }[];
  end: number;
  containsNonASCII: boolean;
  verified: boolean;
}

export interface WhitespaceCall {
  from: number;
  to: number;
  firstByte: number;
  earlyOut: boolean;
  path: "early" | "scalar" | "vector";
  end: number;
  runLength: number;
  lanes: { offset: number; byte: number; isWhitespace: boolean }[];
}

export interface WhitespaceTrace {
  sample: string;
  bytes: number[];
  calls: WhitespaceCall[];
}

export interface ContainerStep {
  index: number;
  event: string;
  text?: string;
  depthBefore: number;
  depthAfter: number;
  containersAfter: string;
  containersBits: number[];
}

export interface ContainerTrace {
  sample: string;
  steps: ContainerStep[];
  maximumDepth: number;
}

export interface NumberCase {
  text: string;
  prefix: string;
  runEnd: number;
  digitCount: number;
  acceptedByShortInteger: boolean;
  value?: number;
  steps: { label: string; detail: string; hex: string; bytes: number[] }[];
  verified: boolean;
}

export interface TraceBundle {
  generatedAt: string;
  arch: string;
  stringRun: StringRunTrace;
  whitespace: WhitespaceTrace;
  containers: ContainerTrace;
  number: { cases: NumberCase[] };
}
