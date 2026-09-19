import { describe, expect, it } from "vitest";
import { content, pipeline, section } from "../test/fixtures";
import type { PipelineNode } from "../types";
import { sectionsByPath } from "./evidence";
import { citations, lanes, paragraphs } from "./overview";

const runs = section({ title: "Runs, not bytes", line: 58 });
const byPath = sectionsByPath([runs]);
const nodes = [{ id: "string-run", title: "streamStringRun" }] as unknown as PipelineNode[];

describe("paragraphs", () => {
  it("reads one paragraph written bare or many written as a list", () => {
    expect(paragraphs({ title: "a", detail: "one" })).toEqual(["one"]);
    expect(paragraphs({ title: "a", detail: ["one", "two"] })).toEqual(["one", "two"]);
  });
});

const twoNodes = [
  { id: "string-run", title: "streamStringRun" },
  { id: "escapes", title: "Escapes, decoded and coalesced" }
] as unknown as PipelineNode[];

describe("citations", () => {
  it("links a node into the chart and a section into the repository", () => {
    expect(citations({ title: "a", detail: "d", node: "string-run", doc: [runs.path] }, byPath, nodes)).toEqual([
      { kind: "node", id: "string-run", label: "streamStringRun", href: "#/flow/string-run" },
      {
        kind: "doc",
        id: runs.path,
        label: "Runs, not bytes",
        href: "https://github.com/mhayes853/swift-stream-parsing/blob/main/NEW_ARCHITECTURE.md#L58"
      }
    ]);
  });

  it("links every node a step is spread across, in the order written", () => {
    const item = { title: "a", detail: "d", node: ["escapes", "string-run"] };
    expect(citations(item, byPath, twoNodes).map((c) => c.id)).toEqual(["escapes", "string-run"]);
  });

  it("drops what does not resolve rather than drawing a dead link", () => {
    expect(citations({ title: "a", detail: "d", node: "renamed", doc: ["gone"] }, byPath, nodes)).toEqual([]);
  });

  it("names the chart's lanes in the chart's order, and drops one it no longer has", () => {
    const stages = pipeline.stages;
    const item = { title: "a", detail: "d", stage: ["strings", "entry", "renamed"] };
    expect(lanes(item, stages).map((s) => s.id)).toEqual(["entry", "strings"]);
    expect(lanes({ title: "a", detail: "d" }, stages)).toEqual([]);
  });

  it("resolves every lane the real overview points at", () => {
    for (const item of pipeline.overview.how) {
      const wanted = typeof item.stage === "string" ? 1 : (item.stage?.length ?? 0);
      expect(lanes(item, pipeline.stages).length, item.title).toBe(wanted);
    }
  });

  it("resolves every citation in the real overview", () => {
    const all = sectionsByPath(content.doc.sections);
    const items = [...pipeline.overview.how, ...pipeline.overview.why];
    expect(items.length).toBeGreaterThan(0);
    for (const item of items) {
      const expected = (typeof item.node === "string" ? 1 : (item.node?.length ?? 0)) + (item.doc?.length ?? 0);
      expect(citations(item, all, pipeline.nodes).length, item.title).toBe(expected);
      expect(paragraphs(item).join("").trim().length, item.title).toBeGreaterThan(0);
    }
  });
});
