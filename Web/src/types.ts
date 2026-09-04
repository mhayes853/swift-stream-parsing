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

/** When a section was written and last rewritten, recovered from the log's git history. */
export interface DocHistory {
  /** ISO 8601 author date, kept with the offset it was written at. */
  recorded: string;
  recordedCommit: string;
  recordedSubject: string;
  revised: string;
  revisedCommit: string;
  revisedSubject: string;
  /** Commits that changed this section's body, the one that introduced it included. */
  revisions: number;
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
  history?: DocHistory;
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
    datedSections: number;
    firstRecorded?: string;
    lastRecorded?: string;
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

export type VizKind =
  | "stringRun"
  | "whitespace"
  | "containers"
  | "number"
  | "movemask"
  | "whitespaceTable"
  | "numberTable"
  | "utf8"
  | "escapes"
  | "sinkCalls"
  | "dispositions"
  | "skipRun"
  | "keyMatch"
  | "fieldTable"
  | "frames"
  | "schemaRouting"
  | "streamString"
  | "collections"
  | "views";

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

/**
 * One step of a node's own algorithm — an instruction, a test, or a call it makes.
 *
 * The pipeline graph says which functions reach which. This says what the one function does, and
 * it is the only place a branch *inside* a kernel is written down. The extractor holds it to the
 * same standard as the pipeline graph: every arrow labelled, every step reachable from the first,
 * and at least one step that ends the algorithm.
 */
export interface AlgorithmStep {
  id: string;
  title: string;
  /** The short label under the title — a width, a cost, an attribute. */
  kicker?: string;
  detail: string;
  /** `File.swift:symbol`, and required to be one the node already lists as evidence. */
  source?: string;
  ordering?: "ordered" | "unordered";
  next: PipelineEdge[];
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
  /** The control flow inside this node. The first entry is the entry point. */
  steps: AlgorithmStep[];
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
  /** The token's byte range in the sample, from the parser's own spans where it hands one over. */
  offset: number;
  length: number;
  depthBefore: number;
  depthAfter: number;
  containersAfter: string;
  containersBits: number[];
}

export interface ContainerTrace {
  sample: string;
  steps: ContainerStep[];
  maximumDepth: number;
  offsetsVerified: boolean;
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

/** A table-driven membership test: index with part of the byte, combine what comes back. */
export interface LookupTable {
  name: string;
  indexedBy: string;
  entries: number[];
  format: "byte" | "bits";
  bitLabels: string[];
  note: string;
}

export interface TableLane {
  lane: number;
  byte: number;
  indices: number[];
  values: number[];
  hit: boolean;
}

export interface TableTrace {
  kernel: string;
  summary: string;
  replaces: string;
  sample: string;
  /** The sample's bytes; the lanes cover the first sixteen of them. */
  bytes: number[];
  tables: LookupTable[];
  lanes: TableLane[];
  combine: "equal" | "and";
  verified: boolean;
}

export interface UTF8Lane {
  lane: number;
  byte: number;
  previous1: number;
  previous2: number;
  previous3: number;
  indices: number[];
  values: number[];
  special: number;
  mustContinue: number;
  error: number;
  classes: string[];
  role: "ascii" | "continuation" | "lead2" | "lead3" | "lead4" | "invalid";
}

export interface UTF8Trace {
  sample: string;
  bytes: number[];
  tables: LookupTable[];
  lanes: UTF8Lane[];
  valid: boolean;
  verified: boolean;
}

export interface EscapeTrace {
  entries: { byte: number; source: string; decoded?: number; meaning: string }[];
  /** The whole 128-byte map, recovered by probing the shipped decoder at every index. */
  map: number[];
  verified: boolean;
}

// MARK: - The sink boundary onwards
//
// These are not kernels, so they are not registers: a call log, two frame stacks, storage growing
// a block at a time. Each is recorded by running the shipped thing and reading its own state back
// out — see the note above `SinkCallTrace` in `Trace/TraceModel.swift`.

export interface SinkCall {
  index: number;
  method: string;
  signature: string;
  text?: string | null;
  offset?: number | null;
  length?: number | null;
  takesSpan: boolean;
  depthAfter: number;
  group: "structure" | "key" | "whole" | "chunked";
}

export interface SinkCallTrace {
  sample: string;
  bytes: number[];
  calls: SinkCall[];
  verified: boolean;
}

export interface DispositionTrace {
  sample: string;
  bytes: number[];
  skippedKey: string;
  streamed: SinkCall[];
  skipped: SinkCall[];
  /** Parallel to `streamed`: whether the skipping run received that call too. */
  delivered: boolean[];
  skipFrom: number;
  skipTo: number;
  verified: boolean;
}

export interface SkipRunStep {
  offset: number;
  byte: number;
  action: "open" | "close" | "string" | "separator" | "number" | "literal" | "done";
  scanner?: string | null;
  next: number;
  depthBefore: number;
  depthAfter: number;
  containers: string;
  emits: boolean;
}

export interface SkipRunTrace {
  sample: string;
  bytes: number[];
  from: number;
  startDepth: number;
  steps: SkipRunStep[];
  end: number;
  shippedEnd: number;
  verified: boolean;
}

export interface FieldEntry {
  index: number;
  key: string;
  keyWord: string;
  wordBytes: number[];
  keyLength: number;
  kind: string;
  offset: number;
  hash: string;
  bucket: number;
}

export interface FieldProbeStep {
  bucket: number;
  entry: number;
  wordEqual: boolean;
  lengthEqual: boolean;
  tailChecked: boolean;
  tailEqual: boolean;
  hit: boolean;
}

export interface FieldProbe {
  key: string;
  bytes: number[];
  word: string;
  wordBytes: number[];
  length: number;
  hash: string;
  bytesHash: string;
  steps: FieldProbeStep[];
  shipped: number;
  mirrored: number;
  verified: boolean;
}

export interface FieldTable {
  name: string;
  strategy: "scan" | "indexed" | "none";
  threshold: number;
  entries: FieldEntry[];
  slots: number[];
  probes: FieldProbe[];
}

export interface FieldMatchTrace {
  tables: FieldTable[];
  verified: boolean;
}

export interface Frame {
  schema: number;
  storageOffset?: number | null;
  pendingField: number;
  field?: string | null;
}

export interface FrameStep {
  index: number;
  call: string;
  text?: string | null;
  offset?: number | null;
  length?: number | null;
  frames: Frame[];
  wrote?: string | null;
}

export interface FrameTrace {
  sample: string;
  bytes: number[];
  rootSize: number;
  schemas: {
    id: number;
    name: string;
    shape: string;
    keyRouting: string;
    fieldCount: number;
  }[];
  members: { name: string; offset: number; size: number; kind: string; schema: number }[];
  steps: FrameStep[];
  verified: boolean;
  result: string;
}

export interface StreamStringTrace {
  inlineCapacity: number;
  firstBlockCapacity: number;
  maximumBlockCapacity: number;
  steps: {
    chunk: string;
    chunkBytes: number;
    inlineCount: number;
    blocks: number[];
    tailCount: number;
    tailCapacity: number;
    utf8Count: number;
    event: "inline" | "promote" | "append" | "seal";
  }[];
  locate: {
    position: number;
    block: number;
    offset: number;
    byte: number;
    region: "inline" | "sealed" | "tail";
  }[];
  verified: boolean;
}

export interface CollectionTrace {
  array: {
    blockCapacity: number;
    initialTailCapacity: number;
    steps: {
      index: number;
      value: number;
      blocks: number[];
      tailCount: number;
      tailCapacity: number;
      pending?: number | null;
      count: number;
      event: "open" | "commit" | "seal";
    }[];
  };
  dictionary: {
    indexThreshold: number;
    steps: {
      key: string;
      hash: string;
      entryCount: number;
      storedValueCount: number;
      tableCount: number;
      pendingSlot: number;
      event: "open" | "commit" | "index";
    }[];
    slots: number[];
    lookups: { key: string; hash: string; buckets: number[]; slot: number; found: boolean }[];
  };
  verified: boolean;
}

export interface ViewTrace {
  typeName: string;
  size: number;
  stride: number;
  members: {
    name: string;
    offset: number;
    size: number;
    kind: string;
    value: string;
    indirect: boolean;
  }[];
  verified: boolean;
}

export interface TraceBundle {
  generatedAt: string;
  arch: string;
  stringRun: StringRunTrace;
  whitespace: WhitespaceTrace;
  containers: ContainerTrace;
  number: { cases: NumberCase[] };
  whitespaceTable: TableTrace;
  numberTable: TableTrace;
  utf8: UTF8Trace;
  escapes: EscapeTrace;
  sinkCalls: SinkCallTrace;
  dispositions: DispositionTrace;
  skipRun: SkipRunTrace;
  fieldMatch: FieldMatchTrace;
  frames: FrameTrace;
  streamString: StreamStringTrace;
  collections: CollectionTrace;
  views: ViewTrace;
}
