import { describe, expect, it } from "vitest";
import { history, section } from "../test/fixtures";
import { buildIndex, hit, markTerms, matches, parseQuery, search } from "./search";

const long = "word ".repeat(40);
const sections = [
  section({
    title: "Rejected: a movemask for the number scanner",
    verdict: "rejected",
    summary: "Slower on canada.",
    history: history("2026-08-20T10:00:00-07:00")
  }),
  section({
    title: "Landed: whole tokens in the run",
    verdict: "landed",
    summary: "Twitter gains.",
    markdown: `${long}the \`shrn\` movemask landed here ${long} and a second movemask`,
    history: history("2026-08-29T10:00:00-07:00")
  }),
  section({
    title: "Rejected: a wider peel",
    chapter: "Cheap first tiers",
    verdict: "rejected",
    summary: "It cost citm.",
    history: history("2026-08-25T10:00:00-07:00")
  })
];
const index = buildIndex(sections);

describe("parseQuery", () => {
  it("lower-cases and splits on any whitespace", () => {
    expect(parseQuery("  Shrn \t MOVEMASK ")).toEqual(["shrn", "movemask"]);
    expect(parseQuery("   ")).toEqual([]);
  });
});

describe("matches", () => {
  it("needs every term, anywhere in the section", () => {
    expect(matches(index[1], ["whole", "shrn"])).toBe(true);
    expect(matches(index[1], ["whole", "canada"])).toBe(false);
  });

  it("matches across a span of code, because the markup is gone", () => {
    expect(matches(index[1], ["shrn movemask"])).toBe(true);
  });
});

describe("hit", () => {
  it("prefers the title, then the summary or chapter, then the body", () => {
    expect(hit(index[0], ["movemask"]).where).toBe("title");
    expect(hit(index[0], ["canada"]).where).toBe("summary");
    expect(hit(index[2], ["cheap"]).where).toBe("summary");
    expect(hit(index[1], ["shrn"]).where).toBe("body");
  });

  it("carries the sentence around a body hit, widened to whole words", () => {
    const found = hit(index[1], ["shrn"]);
    expect(found.snippet?.match).toBe("shrn");
    expect(found.snippet?.before.startsWith("…")).toBe(true);
    expect(found.snippet?.after.endsWith("…")).toBe(true);
    // Never opens or closes mid-word: every word in the widened window is whole.
    expect(found.snippet?.before.slice(1).split(" ").every((w) => w === "" || w === "word" || w === "the")).toBe(true);
  });

  it("counts the occurrences of the term that hit", () => {
    expect(hit(index[1], ["movemask"]).count).toBe(2);
  });

  it("draws no snippet for a title or summary hit", () => {
    expect(hit(index[0], ["movemask"]).snippet).toBeUndefined();
  });
});

describe("search", () => {
  it("lists every section, newest first, with no query", () => {
    const { hits, hidden } = search(index, [], "all");
    expect(hits.map((h) => h.section.title)).toEqual([
      "Landed: whole tokens in the run",
      "Rejected: a wider peel",
      "Rejected: a movemask for the number scanner"
    ]);
    expect(hidden).toBe(0);
  });

  it("sorts oldest first on request", () => {
    expect(search(index, [], "all", true).hits[0].section.title).toBe(
      "Rejected: a movemask for the number scanner"
    );
  });

  it("counts the matches the verdict filter hides, rather than dropping them silently", () => {
    const { hits, hidden } = search(index, ["movemask"], "rejected");
    expect(hits.map((h) => h.section.verdict)).toEqual(["rejected"]);
    expect(hidden).toBe(1);
  });

  it("finds nothing for a term no section has", () => {
    expect(search(index, ["zzz"], "all")).toEqual({ hits: [], hidden: 0 });
  });
});

describe("markTerms", () => {
  it("marks every occurrence, ignoring case and keeping the original text", () => {
    expect(markTerms("Movemask and movemask", ["movemask"])).toEqual([
      { text: "Movemask", marked: true },
      { text: " and ", marked: false },
      { text: "movemask", marked: true }
    ]);
  });

  it("does not nest marks when terms overlap", () => {
    const runs = markTerms("abcdef", ["abc", "bcd"]);
    expect(runs).toEqual([
      { text: "abc", marked: true },
      { text: "def", marked: false }
    ]);
  });

  it("returns the text unmarked with no terms", () => {
    expect(markTerms("plain", [])).toEqual([{ text: "plain", marked: false }]);
  });
});
