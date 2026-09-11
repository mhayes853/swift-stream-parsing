import { describe, expect, it } from "vitest";
import { at, neighbours, pathOf, placeLabels, rankGraph, route, wrap } from "./graph";

describe("wrap", () => {
  it("breaks at word boundaries under the line length", () => {
    expect(wrap("Strings and escapes", 10, 3)).toEqual(["Strings", "and", "escapes"]);
  });

  it("appends what does not fit to the last line rather than dropping it", () => {
    // A silently truncated label looked exactly like a rendering bug.
    expect(wrap("Strings and escapes", 10, 2)).toEqual(["Strings", "and escapes"]);
  });

  it("never breaks a single word", () => {
    expect(wrap("parseDispatching", 4)).toEqual(["parseDispatching"]);
  });
});

describe("rankGraph", () => {
  const graph: Record<string, string[]> = {
    entry: ["head"],
    head: ["body", "exit"],
    body: ["head"],
    exit: []
  };
  const rank = rankGraph(Object.keys(graph), (id) => graph[id]);

  it("puts a loop's head above its body, so the returning arrow reads as a return", () => {
    expect(rank.get("entry")).toBe(0);
    expect(rank.get("head")).toBe(1);
    expect(rank.get("body")).toBe(2);
  });

  it("ranks by the longest path to a step", () => {
    expect(rank.get("exit")).toBe(2);
  });

  it("still places a step the entry cannot reach", () => {
    const orphaned = rankGraph(["a", "b"], () => []);
    expect([...orphaned.keys()]).toEqual(["a", "b"]);
  });
});

describe("route", () => {
  const box = (row: number, cx: number) => ({ row, cx, cy: row * 100 + 50 });

  it("runs a forward edge from the bottom of one box to the top of the next", () => {
    const [start, , , end] = route(box(0, 100), box(1, 300), 80, 40);
    expect(start).toEqual([100, 70]);
    expect(end).toEqual([300, 130]);
  });

  it("arcs a same-row edge above the boxes, between their near sides", () => {
    const [start, c1, , end] = route(box(0, 100), box(0, 300), 80, 40);
    expect(start).toEqual([140, 50]);
    expect(end).toEqual([260, 50]);
    // The apex clears the top of the boxes (cy - 20) by enough to seat a label.
    expect(at([start, c1, [c1[0], c1[1]], end], 0.5)[1]).toBeLessThan(50 - 20);
  });

  it("sends a back edge out to the left, further for each spread", () => {
    const near = route(box(2, 200), box(0, 200), 80, 40, 0);
    const far = route(box(2, 200), box(0, 200), 80, 40, 1);
    expect(near[0][0]).toBe(160);
    expect(far[1][0]).toBeLessThan(near[1][0]);
  });
});

describe("at", () => {
  it("is the curve's endpoints at 0 and 1", () => {
    const curve = route({ row: 0, cx: 0, cy: 0 }, { row: 1, cx: 50, cy: 100 }, 20, 20);
    expect(at(curve, 0)).toEqual(curve[0]);
    expect(at(curve, 1)).toEqual(curve[3]);
  });
});

describe("pathOf", () => {
  it("writes a cubic as SVG path data", () => {
    expect(pathOf([[0, 1], [2, 3], [4, 5], [6, 7]])).toBe("M 0 1 C 2 3, 4 5, 6 7");
  });
});

describe("placeLabels", () => {
  it("slides converging labels apart rather than stacking them", () => {
    // Three edges into one node, with midpoints within a few pixels of each other.
    const target = { row: 1, cx: 200, cy: 150 };
    const edges = [150, 200, 250].map((cx) => {
      const cp = route({ row: 0, cx, cy: 50 }, target, 60, 30);
      const [mx, my] = at(cp, 0.5);
      return { cp, text: "a label of some length", mx, my };
    });
    placeLabels(edges, [], 60, 30);
    for (let i = 0; i < edges.length; i++) {
      for (let j = i + 1; j < edges.length; j++) {
        const apart = Math.abs(edges[i].mx - edges[j].mx) > 130 || Math.abs(edges[i].my - edges[j].my) >= 13;
        expect(apart).toBe(true);
      }
    }
  });
});

describe("neighbours", () => {
  const edges: [string, string][] = [["a", "b"], ["b", "c"], ["d", "a"]];

  it("is the active node and everything one edge away, both directions", () => {
    expect([...neighbours("a", edges)].sort()).toEqual(["a", "b", "d"]);
  });

  it("is empty with nothing active", () => {
    expect(neighbours(null, edges).size).toBe(0);
  });
});
