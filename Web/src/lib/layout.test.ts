import { describe, expect, it } from "vitest";
import { content, pipeline } from "../test/fixtures";
import { TITLE_PER_CHAR, TITLE_SIZE, balanced, fit, layoutAlgorithm, layoutFor as algoLayoutFor } from "./algorithmLayout";
import { sectionsByPath } from "./evidence";
import { NODE_H, cardBox, layoutFlow, layoutFor as flowLayoutFor, leaderPath } from "./flowLayout";

// Both charts are laid out from measurements rather than drawn by hand, so their layouts are
// checked against every node the site actually draws — at a desktop panel's width and a phone's.

const PANEL_WIDTHS = [630, 347];
const PAGE_WIDTHS = [1130, 361];

describe("balanced", () => {
  it("splits at the space that makes the longer line shortest", () => {
    expect(balanced("up to 64 bytes live in the value")).toEqual(["up to 64 bytes", "live in the value"]);
  });

  it("splits a lone identifier at a camel-case hump", () => {
    expect(balanced("promoteSizedInlineStorage")).toEqual(["promoteSized", "InlineStorage"]);
  });

  it("leaves a word with nowhere to break whole", () => {
    expect(balanced("lowercase")).toEqual(["lowercase"]);
  });
});

describe("fit", () => {
  it("leaves a label that fits at full size", () => {
    expect(fit("appendBlocked", 168, TITLE_SIZE, TITLE_PER_CHAR, 2)).toEqual({ lines: ["appendBlocked"], size: TITLE_SIZE });
  });

  it("balances a label greedy wrapping cannot fit, before shrinking it", () => {
    const { lines, size } = fit("promoteSizedInlineStorage", 104, TITLE_SIZE, TITLE_PER_CHAR, 2);
    expect(lines).toEqual(["promoteSized", "InlineStorage"]);
    expect(size).toBeGreaterThan(10);
  });

  it("shrinks rather than truncates, but not below legibility", () => {
    const { lines, size } = fit("StreamStringRun(end:containsNonASCII:)", 104, TITLE_SIZE, TITLE_PER_CHAR, 1);
    expect(lines.join("")).toBe("StreamStringRun(end:containsNonASCII:)");
    expect(size).toBe(7.5);
  });
});

describe("algorithm chart layout", () => {
  it("narrows the gap only once the nodes are at their floor", () => {
    for (let width = 520; width <= 760; width += 4) {
      const geo = algoLayoutFor(width, 5);
      expect(geo.nodeW).toBeGreaterThanOrEqual(104);
      if (geo.colGap < 14) expect(geo.nodeW, `${width}px`).toBe(104);
      // Five arms fit whenever they can at the smallest gap that still reads as two boxes.
      if (width >= 5 * 104 + 4 * 9 + 16) expect(geo.width, `${width}px`).toBeLessThanOrEqual(width);
    }
  });

  for (const width of PANEL_WIDTHS) {
    it(`places every step of every node at ${width}px`, () => {
      for (const node of pipeline.nodes) {
        const layout = layoutAlgorithm(node, width);
        expect(layout.placed.length, node.id).toBe(node.steps.length);
        expect(layout.edges.length, node.id).toBe(node.steps.reduce((n, s) => n + s.next.length, 0));

        // The entry is alone on the top row, and nothing is drawn outside the view box.
        const entry = layout.placed.find((p) => p.step.id === node.steps[0].id)!;
        expect(entry.row, node.id).toBe(0);
        for (const p of layout.placed) {
          expect(p.cx - layout.geo.nodeW / 2, node.id).toBeGreaterThanOrEqual(layout.view.left);
          expect(p.cx + layout.geo.nodeW / 2, node.id).toBeLessThanOrEqual(layout.view.left + layout.view.width);
        }

        // Shrunk by at most 12%, and only when it would otherwise scroll.
        expect(layout.scale, node.id).toBeGreaterThanOrEqual(0.88);
        expect(layout.scale, node.id).toBeLessThanOrEqual(1);
      }
    });
  }

  it("never puts two steps on top of each other", () => {
    for (const node of pipeline.nodes) {
      const { placed, geo } = layoutAlgorithm(node, 630);
      for (const a of placed) {
        for (const b of placed) {
          if (a === b || a.row !== b.row) continue;
          expect(Math.abs(a.cx - b.cx), node.id).toBeGreaterThanOrEqual(geo.nodeW);
        }
      }
    }
  });
});

describe("page chart layout", () => {
  const sections = sectionsByPath(content.doc.sections);

  it("reserves a rail for the hover card only where there is hover", () => {
    expect(flowLayoutFor(1130, 4, true).railW).toBeGreaterThanOrEqual(250);
    expect(flowLayoutFor(1130, 4, false).railW).toBe(0);
  });

  for (const width of PAGE_WIDTHS) {
    for (const rail of [true, false]) {
      it(`places every node once, in its stage's row, at ${width}px${rail ? " with the rail" : ""}`, () => {
        const layout = layoutFlow(pipeline, sections, width, rail);
        expect(layout.placed.map((p) => p.node.id).sort()).toEqual(pipeline.nodes.map((n) => n.id).sort());
        for (const p of layout.placed) {
          expect(layout.rows[p.row].nodes).toContain(p.node);
          expect(p.cx + layout.geo.nodeW / 2).toBeLessThanOrEqual(layout.geo.graphWidth);
        }
        expect(layout.edges.length).toBe(pipeline.nodes.reduce((n, node) => n + node.next.length, 0));
        expect(layout.width).toBe(layout.geo.graphWidth + layout.geo.railW);
      });
    }
  }

  it("keeps the hover card on the canvas, facing its node where it can", () => {
    const layout = layoutFlow(pipeline, sections, 1130, true);
    for (const p of layout.placed) {
      const box = cardBox(p, 400, layout);
      expect(box.top).toBeGreaterThanOrEqual(8);
      expect(box.top + box.height).toBeLessThanOrEqual(layout.height - 8 + 0.001);
      expect(box.left).toBeGreaterThan(layout.geo.graphWidth);
    }
    // A card no taller than a node sits level with it.
    const middle = layout.placed[Math.floor(layout.placed.length / 2)];
    expect(cardBox(middle, NODE_H, layout).top).toBe(middle.cy - NODE_H / 2);
  });

  it("draws the leader from the card's edge to the node's right side", () => {
    const layout = layoutFlow(pipeline, sections, 1130, true);
    const p = layout.placed[0];
    const path = leaderPath(p, 900, 60, layout.geo.nodeW);
    expect(path.startsWith("M 900 60 ")).toBe(true);
    expect(path.endsWith(`${p.cx + layout.geo.nodeW / 2} ${p.cy}`)).toBe(true);
  });

  it("counts each node's experiments from the log", () => {
    const layout = layoutFlow(pipeline, sections, 1130, true);
    const total = layout.placed.reduce((n, p) => n + p.landed + p.rejected, 0);
    expect(total).toBeGreaterThan(0);
  });
});
