// The arithmetic behind the visualizations: how a byte is drawn, where a step sits on the timeline,
// which part of the input it touches, and the one kernel computation (`streamFirstHitLane`) that
// the movemask animation re-derives rather than reads off the trace.

/** Printable stand-in for a byte, so a control character still occupies its lane visibly. */
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

/** Lanes whose value changed against the previous step, so the pulse marks the delta. With no
 *  previous step nothing changed. */
export function diff(now: number[], before: number[] | undefined): boolean[] {
  return now.map((v, i) => before !== undefined && before[i] !== v);
}

// MARK: - The step timeline
//
// A stack of registers, a call log or a block list is stepped through, and every row in it is one
// of three things at any point: not computed yet, computed by this step, or already computed. A
// future row keeps its space and shows nothing, so nothing reflows as the animation runs.

export type RowPhase = "past" | "now" | "future";

export function phaseOf(row: number, current: number): RowPhase {
  if (row < current) return "past";
  if (row === current) return "now";
  return "future";
}

/** A flat step index over `perBlock` instructions repeated per block: which block, which one. */
export function blockStep(index: number, perBlock: number): { block: number; op: number } {
  return { block: Math.floor(index / perBlock), op: index % perBlock };
}

// MARK: - The input tape

export type TapeKind = "done" | "window" | "cursor" | "next";

export interface TapeMark {
  /** Inclusive byte offset. */
  from: number;
  /** Exclusive byte offset. */
  to: number;
  kind: TapeKind;
}

/** The mark a byte is drawn with. Later marks win, so a `cursor` after a `window` shows through. */
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

/**
 * Where the input has been read up to before step `index`: the end of the last span any earlier
 * step carried. A step with no span (a container open, a decoded escape) does not move it.
 */
export function readUpTo(steps: Spanned[], index: number): number | undefined {
  for (let i = Math.min(index, steps.length) - 1; i >= 0; i--) {
    const { offset, length } = steps[i];
    if (offset != null) return offset + (length ?? 0);
  }
  return undefined;
}

// MARK: - Registers

export interface Cell {
  /** The value in this lane. */
  text: string;
  /** Smaller line underneath — the byte a mask came from, a lane index, a glyph. */
  sub?: string;
  /** Set lanes: 0xFF in a mask, a member of the class under test. */
  on?: boolean;
  /** Lanes past the answer, or otherwise not participating. */
  dim?: boolean;
  /** Overrides the set colour, for the three terminator classes. */
  tone?: string;
  /** Ringed: the lane the whole operation resolves to. */
  marked?: boolean;
  /** This lane's value differs from the previous step's — pulsed rather than merely re-rendered. */
  changed?: boolean;
  title?: string;
}

/** A splatted constant: the same byte in all sixteen lanes, which is what `vdupq_n_u8` costs. */
export function splat(value: string, count = 16): Cell[] {
  return Array.from({ length: count }, () => ({ text: value, dim: true }));
}

/** Eight bytes as the little-endian 64-bit word they load as: the last byte is the high digit. */
export function wordHex(bytes: number[]): string {
  return bytes.map(hex).reverse().join("");
}

export interface FirstHitLane {
  /** The mask's storage, 0xFF where the lane hit, read as two words. */
  low: number[];
  high: number[];
  /** Trailing-zero counts of the two words: a multiple of eight, or 64 for an empty word. */
  lowCount: number;
  highCount: number;
  /** Bit 6 of the low count: 1 exactly when the low word held no hit. */
  lowEmpty: number;
  /** The first lane that hit, or 16 when none did. */
  lane: number;
  /** The arm64 spelling: `shrn` folds every lane to a nibble, so sixteen lanes are one word. */
  nibbles: string;
}

/**
 * `streamFirstHitLane`'s portable form, computed the way the kernel computes it.
 *
 * Bit 6 of the low count *is* "the low word had no hit", so masking the high word's contribution
 * by it needs no select — and with no hit at all both counts are 64, the sum is 8 + 8 = 16, and
 * the bound check is the terminator test.
 */
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
