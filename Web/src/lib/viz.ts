import type { SkipBlockTrace, StructuralBlockCase } from "../types";

export function glyph(byte: number): string {
  switch (byte) {
    case 0x20: return "␣";
    case 0x09: return "⇥";
    case 0x0a: return "⏎";
    case 0x0d: return "⏎";
    case 0x22: return '"';
    case 0x5c: return "\\";
    default:
      if (byte < 0x20) return "␀";
      if (byte > 0x7e) return "·";
      return String.fromCharCode(byte);
  }
}

export function hex(byte: number): string {
  return byte.toString(16).toUpperCase().padStart(2, "0");
}

export function diff(now: number[], before: number[] | undefined): boolean[] {
  return now.map((v, i) => before !== undefined && before[i] !== v);
}

export type RowPhase = "past" | "now" | "future";

export function phaseOf(row: number, current: number): RowPhase {
  if (row < current) return "past";
  if (row === current) return "now";
  return "future";
}

export function blockStep(index: number, perBlock: number): { block: number; op: number } {
  return { block: Math.floor(index / perBlock), op: index % perBlock };
}

export interface StructuralTimelineStep {
  op: "classify" | "gate" | "visit" | "advance" | "give up";
  block: number;
  visit?: number;
  cursor?: number;
  next: number;
  mask: boolean[];
}

export function structuralBlockTimeline(trace: StructuralBlockCase): StructuralTimelineStep[] {
  const steps: StructuralTimelineStep[] = [];
  for (const block of trace.blocks) {
    steps.push({ op: "classify", block: block.index, next: block.offset, mask: block.starts });
    steps.push({ op: "gate", block: block.index, next: block.offset, mask: block.starts });
    for (const [visit, token] of block.visits.entries()) {
      steps.push({
        op: "visit",
        block: block.index,
        visit,
        cursor: token.offset,
        next: token.next,
        mask: token.maskAfter
      });
    }
    const last = block.visits.at(-1);
    steps.push({
      op: block.givesUp ? "give up" : "advance",
      block: block.index,
      next: last?.reanchors ? last.next : block.givesUp ? block.offset : block.offset + 64,
      mask: last?.maskAfter ?? block.starts
    });
  }
  return steps;
}

export interface SkipBlockTimelineStep {
  op: "classify" | "visit" | "carry";
  block: number;
  visit?: number;
  cursor?: number;
  next: number;
  mask: boolean[];
}

export function skipBlockTimeline(trace: SkipBlockTrace): SkipBlockTimelineStep[] {
  const steps: SkipBlockTimelineStep[] = [];
  for (const block of trace.blocks) {
    steps.push({ op: "classify", block: block.index, next: block.offset, mask: block.brackets });
    for (const [visit, bracket] of block.visits.entries()) {
      steps.push({
        op: "visit",
        block: block.index,
        visit,
        cursor: bracket.offset,
        next: bracket.offset + 1,
        mask: bracket.maskAfter
      });
    }
    const last = block.visits.at(-1);
    steps.push({
      op: "carry",
      block: block.index,
      next: last?.emits ? last.offset + 1 : block.offset + 64,
      mask: last?.maskAfter ?? block.brackets
    });
  }
  return steps;
}

export type TapeKind = "done" | "window" | "cursor" | "next";

export interface TapeMark {
  from: number;
  to: number;
  kind: TapeKind;
}

export function tapeKindAt(offset: number, marks: TapeMark[]): TapeKind | undefined {
  let out: TapeKind | undefined;
  for (const mark of marks) {
    if (offset >= mark.from && offset < mark.to) out = mark.kind;
  }
  return out;
}

interface Spanned {
  offset?: number | null;
  length?: number | null;
}

export function readUpTo(steps: Spanned[], index: number): number | undefined {
  for (let i = Math.min(index, steps.length) - 1; i >= 0; i--) {
    const { offset, length } = steps[i];
    if (offset != null) return offset + (length ?? 0);
  }
  return undefined;
}

export interface Cell {
  text: string;
  sub?: string;
  on?: boolean;
  dim?: boolean;
  tone?: string;
  marked?: boolean;
  changed?: boolean;
  title?: string;
}

export function splat(value: string, count = 16): Cell[] {
  return Array.from({ length: count }, () => ({ text: value, dim: true }));
}

export function wordHex(bytes: number[]): string {
  return bytes.map(hex).reverse().join("");
}

export interface FirstHitLane {
  low: number[];
  high: number[];
  lowCount: number;
  highCount: number;
  lowEmpty: number;
  lane: number;
  nibbles: string;
}

// Bit 6 of the low count is set exactly when the low word had no hit.
export function firstHitLane(hit: boolean[]): FirstHitLane {
  const bytes = hit.map((on) => (on ? 0xff : 0x00));
  const low = bytes.slice(0, 8);
  const high = bytes.slice(8, 16);
  const tz = (word: number[]) => {
    const i = word.findIndex((b) => b !== 0);
    return i === -1 ? 64 : i * 8;
  };
  const lowCount = tz(low);
  const highCount = tz(high);
  const lowEmpty = lowCount >> 6;
  return {
    low,
    high,
    lowCount,
    highCount,
    lowEmpty,
    lane: (lowCount >> 3) + ((highCount >> 3) & (lowEmpty ? 0xff : 0)),
    nibbles: bytes.map((b) => (b ? "F" : "0")).reverse().join("")
  };
}
