import { describe, expect, it } from "vitest";
import { formatRoute, parseRoute } from "./route";

const ids = new Set(["dispatcher", "structural-run"]);

describe("route", () => {
  it("reads a view and an open node out of the hash", () => {
    expect(parseRoute("#/flow/structural-run", ids)).toEqual({ view: "flow", node: "structural-run" });
    expect(parseRoute("#/graveyard", ids)).toEqual({ view: "graveyard", node: null });
    expect(parseRoute("#/payloads", ids)).toEqual({ view: "payloads", node: null });
  });

  it("falls back to the parse path with nothing open", () => {
    expect(parseRoute("", ids)).toEqual({ view: "flow", node: null });
    expect(parseRoute("#/nowhere", ids)).toEqual({ view: "flow", node: null });
    expect(parseRoute("#/flow/renamed-node", ids)).toEqual({ view: "flow", node: null });
  });

  it("only opens a node on the parse path", () => {
    expect(parseRoute("#/graveyard/dispatcher", ids)).toEqual({ view: "graveyard", node: null });
  });

  it("round-trips", () => {
    for (const route of [
      { view: "flow", node: null },
      { view: "flow", node: "dispatcher" },
      { view: "graveyard", node: null },
      { view: "payloads", node: null }
    ] as const) {
      expect(parseRoute(formatRoute(route), ids)).toEqual(route);
    }
  });
});
