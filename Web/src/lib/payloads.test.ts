import { describe, expect, it } from "vitest";
import { section } from "../test/fixtures";
import type { Measurement } from "../types";
import { deltaRows, divergingBar, payloadCounts, payloadName, rowsFor } from "./payloads";

const m = (payload: string, value: number, isDelta = true): Measurement => ({
  payload,
  rowLabel: "row",
  column: "col",
  value,
  isDelta
});

const sections = [
  section({ title: "A", measurements: [m("twitter", 4.7), m("canada", -2.1), m("canada", 900, false)] }),
  section({ title: "B", measurements: [m("canada", 11.8)] })
];

describe("payloads", () => {
  const rows = deltaRows(sections);

  it("keeps only signed deltas, each with the section it came from", () => {
    expect(rows.map((r) => [r.payload, r.value, r.section.title])).toEqual([
      ["twitter", 4.7, "A"],
      ["canada", -2.1, "A"],
      ["canada", 11.8, "B"]
    ]);
  });

  it("orders payloads by how often they were measured", () => {
    expect(payloadCounts(rows)).toEqual([
      ["canada", 2],
      ["twitter", 1]
    ]);
  });

  it("lists one payload's deltas, largest gain first", () => {
    expect(rowsFor(rows, "canada").map((r) => r.value)).toEqual([11.8, -2.1]);
  });

  it("names a payload the way the benchmarks do", () => {
    expect(payloadName("citm_catalog")).toBe("citm_catalog.json");
    expect(payloadName("something_new")).toBe("something_new");
  });
});

describe("divergingBar", () => {
  it("grows right from the middle for a gain and left for a loss", () => {
    expect(divergingBar(10, 20)).toEqual({ positive: true, left: 50, width: 25 });
    expect(divergingBar(-20, 20)).toEqual({ positive: false, left: 0, width: 50 });
  });

  it("treats zero as a gain of nothing", () => {
    expect(divergingBar(0, 20)).toEqual({ positive: true, left: 50, width: 0 });
  });
});
