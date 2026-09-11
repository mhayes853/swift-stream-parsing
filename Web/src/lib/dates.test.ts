import { describe, expect, it } from "vitest";
import { history } from "../test/fixtures";
import { instant, span, spanOf, stamp, wasRewritten } from "./dates";

describe("stamp", () => {
  it("keeps the author's clock rather than converting to the reader's", () => {
    // 15:41 in Los Angeles is 22:41 UTC; the log records when somebody was working, so it is 15:41.
    expect(stamp("2026-08-29T15:41:07-07:00")).toBe("29 Aug 2026, 15:41");
    expect(stamp("2026-08-29T15:41:07-07:00", false)).toBe("29 Aug 2026");
  });

  it("drops a leading zero from the day", () => {
    expect(stamp("2026-09-01T09:05:00+02:00")).toBe("1 Sep 2026, 09:05");
  });

  it("says what it has when there is no date", () => {
    expect(stamp(undefined)).toBe("—");
    expect(stamp("not a date")).toBe("not a date");
  });
});

describe("instant", () => {
  it("orders across offsets by the moment, not the string", () => {
    // Lexically "10:00+02:00" sorts after "09:00-07:00", but it happened seven hours earlier.
    expect(instant("2026-08-29T10:00:00+02:00")).toBeLessThan(instant("2026-08-29T09:00:00-07:00"));
  });

  it("puts an undated section first", () => {
    expect(instant(undefined)).toBe(0);
  });
});

describe("span", () => {
  it("names the year once inside one year, and twice across two", () => {
    expect(span("2026-08-11T10:00:00Z", "2026-09-01T10:00:00Z")).toBe("Aug 11 – Sep 1, 2026");
    expect(span("2025-12-30T10:00:00Z", "2026-01-02T10:00:00Z")).toBe("Dec 30 2025 – Jan 2 2026");
  });

  it("is empty when either end is missing", () => {
    expect(span(undefined, "2026-09-01T10:00:00Z")).toBe("");
  });
});

describe("spanOf", () => {
  it("spans the earliest to the latest, in any order, ignoring gaps", () => {
    expect(spanOf(["2026-09-01T10:00:00Z", undefined, "2026-08-11T10:00:00Z"])).toBe("Aug 11 – Sep 1, 2026");
  });

  it("needs two dates to make a span", () => {
    expect(spanOf(["2026-09-01T10:00:00Z"])).toBe("");
  });
});

describe("wasRewritten", () => {
  it("needs a later revision, not just more than one commit", () => {
    expect(wasRewritten(history("2026-08-01T10:00:00Z"))).toBe(false);
    expect(wasRewritten(history("2026-08-01T10:00:00Z", "2026-08-05T10:00:00Z", 3))).toBe(true);
    expect(wasRewritten(history("2026-08-01T10:00:00Z", "2026-08-01T10:00:00Z", 2))).toBe(false);
  });
});
