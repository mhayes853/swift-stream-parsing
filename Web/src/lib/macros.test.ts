import { describe, expect, it } from "vitest";
import { library, macrosContent } from "../test/fixtures";
import { classifyExpansion, decodeWordMatches, regionBlocks, regionTally, wordBytes } from "./macros";

const expansions = macrosContent.examples.map((e) => ({
  test: e.test,
  input: library.snapshots[e.test].input,
  expansion: library.snapshots[e.test].expansion!
}));
const basic = library.snapshots["StreamParseableMacroTests.swift:Basic"].expansion!;

describe("classifyExpansion", () => {
  it("names only regions macros.json describes, for every example", () => {
    const described = new Set(macrosContent.regions.map((r) => r.id));
    for (const { expansion } of expansions) {
      for (const line of classifyExpansion(expansion)) expect(described).toContain(line.region);
    }
  });

  it("keeps every line, in order", () => {
    for (const { expansion } of expansions) {
      expect(classifyExpansion(expansion).map((l) => l.text).join("\n")).toBe(expansion);
    }
  });

  it("finds a struct's regions in the order the generator emits them", () => {
    const order = regionTally(classifyExpansion(basic)).map((r) => r.region);
    const emitted = ["storage", "template", "observation", "view", "ids", "match", "apply", "schema"];
    expect(order.filter((r) => emitted.includes(r))).toEqual(emitted);
    expect(order[0]).toBe("source");
    expect(order).toContain("conversions");
    expect(order).not.toContain("other");
  });

  it("puts the member the member macro adds with the conversions", () => {
    const lines = classifyExpansion(basic);
    const at = lines.findIndex((l) => l.text.includes("var streamPartialValue: Partial"));
    expect(lines[at].region).toBe("conversions");
    expect(lines.find((l) => l.text.includes("var name: String") && !l.text.includes("Partial"))?.region).toBe("source");
  });

  it("classifies each generated member of Basic by its own name", () => {
    const lines = classifyExpansion(basic);
    const regionOf = (needle: string) => lines.find((l) => l.text.includes(needle))?.region;
    expect(regionOf("var name: String.Partial?")).toBe("storage");
    expect(regionOf("_streamInitialValueTemplate")).toBe("template");
    expect(regionOf("streamObservationFields")).toBe("observation");
    expect(regionOf("#if !hasFeature(Embedded)")).toBe("observation");
    expect(regionOf("struct View")).toBe("view");
    expect(regionOf("static func streamView")).toBe("view");
    expect(regionOf("private enum StreamField")).toBe("ids");
    expect(regionOf("static func streamMatchField")).toBe("match");
    expect(regionOf("static func streamApplyNull")).toBe("apply");
    expect(regionOf("streamSchemaEntry =")).toBe("schema");
    expect(regionOf("init?(streamPartial partial: Partial)")).toBe("conversions");
    expect(regionOf("extension Person:")).toBe("declaration");
  });

  it("gives a raw-value enum's library Partial to the declaration", () => {
    const raw = classifyExpansion(library.snapshots["StreamParseableMacroTests.swift:String Raw Value Enum"].expansion!);
    expect(raw.find((l) => l.text.includes("typealias Partial = StreamParsingCore.StreamString"))?.region).toBe("declaration");
    expect(raw.some((l) => l.region === "storage")).toBe(false);
  });

  it("groups consecutive lines into blocks that cover the expansion", () => {
    const blocks = regionBlocks(classifyExpansion(basic));
    expect(blocks.reduce((n, b) => n + b.lines.length, 0)).toBe(basic.split("\n").length);
    for (const [a, b] of blocks.slice(1).map((b, i) => [blocks[i], b])) expect(a.region).not.toBe(b.region);
  });
});

describe("decodeWordMatches", () => {
  it("reads a padded word as little-endian bytes", () => {
    expect(wordBytes("0x0000_0000_656D_616E")).toEqual([0x6e, 0x61, 0x6d, 0x65, 0, 0, 0, 0]);
  });

  it("decodes Basic's matcher back to its member names", () => {
    expect(decodeWordMatches(basic).map((m) => m.key)).toEqual(["name", "age"]);
  });

  it("joins a second word for a key longer than eight bytes", () => {
    const custom = decodeWordMatches(library.snapshots["StreamParseableMacroTests.swift:Custom Member Keys"].expansion!);
    expect(custom.map((m) => m.key)).toEqual(["customKeyName", "name2", "a", "b"]);
    expect(custom[0].words.map((w) => w.offset)).toEqual([0, 8]);
  });

  it("finds the converted keys a strategy wrote during expansion", () => {
    const converted = decodeWordMatches(
      library.snapshots["KeyDecodingStrategyMacroTests.swift:Built-In Strategy Converts Keys During Expansion"].expansion!
    );
    expect(converted.map((m) => m.key)).toContain("user_id");
  });

  it("spells only keys that appear in the source the macro was applied to, or its member names", () => {
    for (const { input, expansion } of expansions) {
      for (const match of decodeWordMatches(expansion)) {
        const spelled = input.includes(`"${match.key}"`) || new RegExp(`\\b${match.key}\\b`).test(input);
        const converted = /convertFrom/.test(input);
        expect(spelled || converted, `${match.key} in ${input}`).toBe(true);
      }
    }
  });
});
