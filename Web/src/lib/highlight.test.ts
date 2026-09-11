import { describe, expect, it } from "vitest";
import { sources } from "../test/fixtures";
import { languageOf, tokenize } from "./highlight";

/** The tokens of a given class, as text. */
const of = (code: string, language: Parameters<typeof tokenize>[1], cls: string) =>
  tokenize(code, language)
    .filter((t) => t.cls === cls)
    .map((t) => t.text);

describe("languageOf", () => {
  it("maps a fence's info string onto the three grammars, and anything else to plain text", () => {
    expect(languageOf("Swift")).toBe("swift");
    expect(languageOf("h")).toBe("c");
    expect(languageOf("arm64")).toBe("asm");
    expect(languageOf("")).toBe("text");
    expect(languageOf(undefined)).toBe("text");
    expect(languageOf("json")).toBe("text");
  });
});

describe("tokenize", () => {
  it("never loses or reorders a character", () => {
    // Highlighting is a view: whatever it does, the text it draws has to be the text it was given.
    const decls = Object.values(sources.sources).flat();
    for (const decl of decls.slice(0, 200)) {
      const language = decl.kind.startsWith("c-") ? "c" : "swift";
      expect(tokenize(decl.code, language).map((t) => t.text).join(""), decl.qualifiedName).toBe(decl.code);
    }
  });

  it("merges adjacent tokens of one class, so the DOM gets a span per run", () => {
    const tokens = tokenize("let a", "swift");
    for (let i = 1; i < tokens.length; i++) expect(tokens[i].cls).not.toBe(tokens[i - 1].cls);
  });

  it("draws a text block as one plain run", () => {
    expect(tokenize("let a = 1", "text")).toEqual([{ text: "let a = 1", cls: "plain" }]);
  });

  describe("swift", () => {
    it("tells keywords, types and attributes apart", () => {
      expect(of("@inline(__always) func run(_ s: StreamString) {}", "swift", "attr")).toEqual(["@inline"]);
      expect(of("@inline(__always) func run(_ s: StreamString) {}", "swift", "kw")).toEqual(["func"]);
      expect(of("@inline(__always) func run(_ s: StreamString) {}", "swift", "type")).toEqual(["StreamString"]);
    });

    it("nests block comments", () => {
      expect(of("/* a /* b */ c */ let", "swift", "com")).toEqual(["/* a /* b */ c */"]);
    });

    it("reads a raw string to its own delimiter", () => {
      expect(of('#"a "quoted" \\n"# + x', "swift", "str")).toEqual(['#"a "quoted" \\n"#']);
    });

    it("keeps an exponent in its number and a member access out of it", () => {
      expect(of("1.5e-3 + 2.max", "swift", "num")).toEqual(["1.5e-3", "2"]);
    });

    it("reads hex digits only in a hex literal, whose exponent is `p`", () => {
      expect(of("0xFF + 0x1.8p-2 + 1e5 + 0b1010", "swift", "num")).toEqual(["0xFF", "0x1.8p-2", "1e5", "0b1010"]);
    });
  });

  describe("c", () => {
    it("runs a directive through its continuation lines", () => {
      expect(of("#define A \\\n  1\nint x;", "c", "attr")).toEqual(["#define A \\\n  1"]);
    });

    it("treats an upper-case macro like an attribute and a `_t` name like a type", () => {
      expect(of("SIMD_INLINE uint8_t f(void)", "c", "attr")).toEqual(["SIMD_INLINE"]);
      expect(of("SIMD_INLINE uint8_t f(void)", "c", "type")).toEqual(["uint8_t"]);
    });
  });

  describe("asm", () => {
    const listing = "; parse\n100210080: cmeq v0.16b, v1.16b, v2.16b\n100210084: b.ne 0x100210090 <_parse+0x10> ; the loop";

    it("marks addresses, mnemonics, registers, symbols and notes", () => {
      expect(of(listing, "asm", "addr")).toEqual(["100210080:", "100210084:"]);
      expect(of(listing, "asm", "mn")).toEqual(["cmeq", "b.ne"]);
      expect(of(listing, "asm", "reg")).toEqual(["v0.16b", "v1.16b", "v2.16b"]);
      expect(of(listing, "asm", "sym")).toEqual(["<_parse+0x10>"]);
      expect(of(listing, "asm", "com")).toEqual(["; parse\n", "; the loop"]);
    });

    it("keeps the listing's text exactly", () => {
      expect(tokenize(listing, "asm").map((t) => t.text).join("")).toBe(listing);
    });
  });
});
