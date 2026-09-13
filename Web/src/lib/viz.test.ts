import { describe, expect, it } from "vitest";
import { traces } from "../test/fixtures";
import {
  blockStep,
  diff,
  firstHitLane,
  glyph,
  hex,
  phaseOf,
  readUpTo,
  skipBlockTimeline,
  splat,
  structuralBlockTimeline,
  tapeKindAt,
  wordHex
} from "./viz";

describe("glyph", () => {
  it("gives every byte something visible to draw", () => {
    expect(glyph(0x20)).toBe("␣");
    expect(glyph(0x09)).toBe("⇥");
    expect(glyph(0x0a)).toBe("⏎");
    expect(glyph(0x00)).toBe("␀");
    expect(glyph(0xc3)).toBe("·");
    expect(glyph(0x41)).toBe("A");
  });
});

describe("hex", () => {
  it("is two upper-case digits", () => {
    expect(hex(0x5)).toBe("05");
    expect(hex(0xff)).toBe("FF");
  });
});

describe("diff", () => {
  it("marks the lanes that changed, and nothing without a previous step", () => {
    expect(diff([1, 2, 3], [1, 0, 3])).toEqual([false, true, false]);
    expect(diff([1, 2], undefined)).toEqual([false, false]);
  });
});

describe("phaseOf", () => {
  it("is past, now or future relative to the current step", () => {
    expect([0, 1, 2].map((row) => phaseOf(row, 1))).toEqual(["past", "now", "future"]);
  });
});

describe("blockStep", () => {
  it("splits a flat index into a block and an instruction within it", () => {
    expect(blockStep(0, 6)).toEqual({ block: 0, op: 0 });
    expect(blockStep(13, 6)).toEqual({ block: 2, op: 1 });
  });
});

describe("block-walk timelines", () => {
  it("keeps the moving grid and four-strike verdict in order", () => {
    const moving = structuralBlockTimeline(traces.structuralBlocks.cases[0]);
    const gated = structuralBlockTimeline(traces.structuralBlocks.cases[1]);
    expect(moving[0].op).toBe("classify");
    expect(moving.some((step) => step.op === "advance" && step.next === 85)).toBe(true);
    expect(gated.at(-1)).toMatchObject({ op: "give up", next: 195 });
  });

  it("settles each skip block's carries after its bracket visits", () => {
    const timeline = skipBlockTimeline(traces.skipBlocks);
    for (const block of traces.skipBlocks.blocks) {
      const slice = timeline.filter((step) => step.block === block.index);
      expect(slice[0].op).toBe("classify");
      expect(slice.at(-1)?.op).toBe("carry");
      expect(slice.filter((step) => step.op === "visit")).toHaveLength(block.visits.length);
    }
  });
});

describe("tapeKindAt", () => {
  const marks = [
    { from: 0, to: 16, kind: "window" as const },
    { from: 3, to: 4, kind: "cursor" as const }
  ];

  it("lets a later mark show through an earlier one", () => {
    expect(tapeKindAt(3, marks)).toBe("cursor");
    expect(tapeKindAt(2, marks)).toBe("window");
  });

  it("treats `to` as exclusive", () => {
    expect(tapeKindAt(16, marks)).toBeUndefined();
  });
});

describe("readUpTo", () => {
  const calls = [{ offset: 0, length: 1 }, { offset: null }, { offset: 4, length: 3 }, {}];

  it("is the end of the last span before the step", () => {
    expect(readUpTo(calls, 3)).toBe(7);
    expect(readUpTo(calls, 2)).toBe(1);
  });

  it("is nothing before any span", () => {
    expect(readUpTo(calls, 0)).toBeUndefined();
  });

  it("does not look past the end", () => {
    expect(readUpTo(calls, 99)).toBe(7);
  });
});

describe("registers", () => {
  it("splats one value across every lane", () => {
    expect(splat("22", 4)).toEqual(Array(4).fill({ text: "22", dim: true }));
  });

  it("writes a little-endian word high byte first", () => {
    expect(wordHex([0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])).toBe("FF00000000000201");
  });
});

describe("firstHitLane", () => {
  const lanes = (...hits: number[]) => Array.from({ length: 16 }, (_, i) => hits.includes(i));

  it("is 16 with no hit: both counts are 64 and the sum is one past the block", () => {
    const r = firstHitLane(lanes());
    expect(r).toMatchObject({ lowCount: 64, highCount: 64, lowEmpty: 1, lane: 16 });
  });

  it("reads the low word alone when it holds a hit", () => {
    expect(firstHitLane(lanes(3, 12))).toMatchObject({ lowCount: 24, lowEmpty: 0, lane: 3 });
  });

  it("adds the high word's count only when the low word is empty", () => {
    expect(firstHitLane(lanes(12))).toMatchObject({ lowCount: 64, highCount: 32, lane: 12 });
  });

  it("folds the lanes to nibbles, highest lane first", () => {
    expect(firstHitLane(lanes(0, 15)).nibbles).toBe("F00000000000000F");
  });

  it("agrees with the lane the shipped kernel reported, on every recorded block", () => {
    // The movemask animation re-derives the lane rather than reading it, so it is held to the same
    // footing as the trace mirrors: it has to land where `streamFirstHitLane` did.
    for (const block of traces.stringRun.blocks) {
      expect(firstHitLane(block.hit).lane).toBe(block.anyHit ? block.hitLane : 16);
    }
  });
});
