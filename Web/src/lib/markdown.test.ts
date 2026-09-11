import { describe, expect, it } from "vitest";
import { content } from "../test/fixtures";
import { flatten, parseBlocks, parseTable, tokenizeInline } from "./markdown";

describe("tokenizeInline", () => {
  it("splits code, bold, emphasis and links out of plain text", () => {
    expect(tokenizeInline("a `b` **c** *d* [e](http://f)")).toEqual([
      { kind: "text", text: "a " },
      { kind: "code", text: "b" },
      { kind: "text", text: " " },
      { kind: "strong", text: "c" },
      { kind: "text", text: " " },
      { kind: "em", text: "d" },
      { kind: "text", text: " " },
      { kind: "link", text: "e", href: "http://f" }
    ]);
  });

  it("leaves emphasis markers inside code alone", () => {
    expect(tokenizeInline("`a *b* c`")).toEqual([{ kind: "code", text: "a *b* c" }]);
  });

  it("reads a bold run as bold rather than as two empty emphases", () => {
    expect(tokenizeInline("**bold**")).toEqual([{ kind: "strong", text: "bold" }]);
  });

  it("does not let an emphasis span a line break", () => {
    expect(tokenizeInline("a * b\nc * d").every((t) => t.kind === "text")).toBe(true);
  });

  it("returns nothing for an empty string", () => {
    expect(tokenizeInline("")).toEqual([]);
  });
});

describe("parseBlocks", () => {
  it("joins a paragraph's lines and splits paragraphs at blank lines", () => {
    expect(parseBlocks("one\ntwo\n\nthree")).toEqual([
      { kind: "p", text: "one two" },
      { kind: "p", text: "three" }
    ]);
  });

  it("keeps a fence's body verbatim, with its language", () => {
    expect(parseBlocks("```swift\nlet a = 1\n\nlet b = 2\n```\nafter")).toEqual([
      { kind: "code", code: "let a = 1\n\nlet b = 2", language: "swift" },
      { kind: "p", text: "after" }
    ]);
  });

  it("folds a wrapped bullet into the item it continues", () => {
    expect(parseBlocks("- first\n  continued\n- second")).toEqual([
      { kind: "ul", items: ["first continued", "second"] }
    ]);
  });

  it("collects table rows and block quotes", () => {
    expect(parseBlocks("| a | b |\n|---|---|\n| 1 | 2 |\n> quoted\n> more")).toEqual([
      { kind: "table", rows: ["| a | b |", "|---|---|", "| 1 | 2 |"] },
      { kind: "quote", text: "quoted more" }
    ]);
  });

  it("ends a paragraph where another block starts", () => {
    expect(parseBlocks("text\n- item").map((b) => b.kind)).toEqual(["p", "ul"]);
  });

  it("parses every section of the log without losing a fence", () => {
    // A fence that never closes would swallow the rest of its section into one code block, so the
    // number of code blocks parsed has to match what the extractor counted.
    for (const section of content.doc.sections) {
      const fences = parseBlocks(section.markdown).filter((b) => b.kind === "code").length;
      expect(fences, section.path).toBe(section.codeBlocks.length);
    }
  });
});

describe("parseTable", () => {
  const table = parseTable([
    "| payload | before | after | Δ |",
    "|:--|--:|--:|--:|",
    "| **twitter** | 1,233 | 1,503 | +21.9% |",
    "| canada | 410 | 398 | −2.9% |"
  ]);

  it("drops the separator row", () => {
    expect(table.headers).toEqual(["payload", "before", "after", "Δ"]);
    expect(table.rows).toHaveLength(2);
  });

  it("marks numbers past the label column, and signed percentages by sign", () => {
    const [twitter, canada] = table.rows;
    expect(twitter.map((c) => c.numeric)).toEqual([false, true, true, true]);
    expect(twitter[3].delta).toBe("pos");
    expect(canada[3].delta).toBe("neg");
    expect(twitter[1].delta).toBeNull();
  });

  it("marks a bold cell", () => {
    expect(table.rows[0][0].strong).toBe(true);
    expect(table.rows[1][0].strong).toBe(false);
  });

  it("reads a table with no separator and no body", () => {
    expect(parseTable(["| only |"])).toEqual({ headers: ["only"], rows: [] });
  });
});

describe("flatten", () => {
  it("keeps what a reader sees and drops the syntax", () => {
    expect(flatten("# Title\n\nThe `shrn` **movemask**, [see](http://x).\n```swift\nlet a\n```")).toBe(
      "Title The shrn movemask, see. let a"
    );
  });
});
