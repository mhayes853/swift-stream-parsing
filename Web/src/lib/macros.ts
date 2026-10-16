// Reading a macro expansion: which generator piece wrote each line, and what the key matcher's
// hex literals spell. Both work on the expansion text a snapshot test asserts, so they describe
// the code the build has already checked.

export type RegionId =
  | "source"
  | "declaration"
  | "storage"
  | "template"
  | "observation"
  | "view"
  | "ids"
  | "match"
  | "apply"
  | "schema"
  | "conversions"
  | "payload"
  | "other";

export interface ExpansionLine {
  text: string;
  region: RegionId;
}

/** A run of consecutive lines in one region, which is how the view draws them. */
export interface RegionBlock {
  region: RegionId;
  lines: string[];
  /** 1-based line number of the first line. */
  start: number;
}

const MODIFIERS =
  /^(?:(?:@\S+|public|package|internal|fileprivate|private|static|final|mutating|nonmutating|nonisolated|override|indirect)\s+)*/;

function indentOf(line: string): number {
  return line.length - line.trimStart().length;
}

/**
 * A line at a member's own indentation that continues that member rather than starting a new one:
 * its closing brace, the `)` ending a multi-line parameter list, or the end of a `#if`.
 */
function continues(trimmed: string): boolean {
  return /^[)}\]]/.test(trimmed) || trimmed.startsWith("#endif") || trimmed.startsWith("#else");
}

function bare(line: string): string {
  return line.trim().replace(MODIFIERS, "");
}

/** What a member at the extension's top level is. */
function extensionMember(line: string): RegionId {
  const decl = bare(line);
  if (/^(struct|typealias) Partial\b/.test(decl)) return "declaration";
  if (/^(init\?|init\(orInitial|func streamValueOrInitial|var streamPartialValue)/.test(decl)) return "conversions";
  if (/^(enum|struct) \w+/.test(decl)) return "payload";
  return "other";
}

/** What a member of the `Partial` struct is. */
function partialMember(line: string): RegionId {
  const decl = bare(line);
  if (/^typealias Partial\b/.test(decl)) return "declaration";
  if (/_streamInitialValueTemplate|streamInitialValue\(/.test(decl)) return "template";
  if (/streamObservationFields/.test(decl)) return "observation";
  if (/^struct View\b|^enum ResolvedView\b|streamView\(|^var resolved\b/.test(decl)) return "view";
  if (/^enum StreamField\b/.test(decl)) return "ids";
  if (/streamMatchField/.test(decl)) return "match";
  if (/streamApply(String|Number|Boolean|Null)\b/.test(decl)) return "apply";
  if (/streamSchemaEntry|streamSchema\b/.test(decl)) return "schema";
  if (/^init\(/.test(decl)) return "storage";
  if (/^(var|let) \w+\s*:/.test(decl)) return "storage";
  return "other";
}

/**
 * The next line at `indent` that starts a declaration, skipping attribute and `#if` lines. An
 * attribute belongs to the declaration after it, and so does a `#if` that wraps one.
 */
function declarationAfter(lines: string[], from: number, indent: number): string {
  for (let i = from; i < lines.length; i++) {
    const trimmed = lines[i].trim();
    if (trimmed === "" || indentOf(lines[i]) !== indent) continue;
    if (trimmed.startsWith("@") && !/\s(var|let|func|init|struct|enum|static)\b/.test(trimmed)) continue;
    if (trimmed.startsWith("#if")) continue;
    return lines[i];
  }
  return "";
}

/**
 * Assigns every line of an expansion to the generator piece that wrote it.
 *
 * The expansion is formatted by SwiftSyntax with two spaces per level, so structure is read from
 * indentation: before the first `extension` is the declaration as written (plus the member the
 * member macro adds); inside the extension, level 2 is the conformance's members and level 4 the
 * `Partial`'s. A member runs from its first line to the next line starting a member at its level.
 */
export function classifyExpansion(expansion: string): ExpansionLine[] {
  const lines = expansion.split("\n");
  const out: ExpansionLine[] = [];
  const firstExtension = lines.findIndex((line) => line.startsWith("extension "));
  let region: RegionId = "source";
  let memberRegion: RegionId = "source";
  let inPartial = false;
  let partialHeaderOpen = false;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    const indent = indentOf(line);

    if (trimmed === "") {
      out.push({ text: line, region });
      continue;
    }

    if (firstExtension === -1 || i < firstExtension) {
      // The declaration as written. Its members sit at level 2; the one the member macro added
      // (`streamPartialValue`) is a conversion.
      if (indent === 0) region = "source";
      else if (indent === 2 && !continues(trimmed)) {
        memberRegion = /streamPartialValue/.test(declarationAfter(lines, i, 2)) ? "conversions" : "source";
        region = memberRegion;
      } else if (indent > 2) region = memberRegion;
      out.push({ text: line, region });
      continue;
    }

    if (indent === 0) {
      region = "declaration";
      inPartial = false;
    } else if (partialHeaderOpen) {
      region = "declaration";
      if (trimmed.endsWith("{")) partialHeaderOpen = false;
    } else if (indent === 2) {
      if (trimmed.startsWith("}") && inPartial) {
        inPartial = false;
        region = "declaration";
      } else if (!continues(trimmed)) {
        region = extensionMember(declarationAfter(lines, i, 2));
        if (region === "declaration" && /struct Partial\b/.test(bare(line))) {
          inPartial = true;
          partialHeaderOpen = !trimmed.endsWith("{");
        }
      }
    } else if (indent === 4 && inPartial) {
      if (!continues(trimmed)) region = partialMember(declarationAfter(lines, i, 4));
    }
    // Deeper lines continue the member they are inside.
    out.push({ text: line, region });
  }
  return out;
}

export function regionBlocks(lines: ExpansionLine[]): RegionBlock[] {
  const blocks: RegionBlock[] = [];
  lines.forEach((line, i) => {
    const last = blocks.at(-1);
    if (last && last.region === line.region) last.lines.push(line.text);
    else blocks.push({ region: line.region, lines: [line.text], start: i + 1 });
  });
  return blocks;
}

/** Regions in the order they first appear, with how many lines each takes. */
export function regionTally(lines: ExpansionLine[]): { region: RegionId; lines: number }[] {
  const counts = new Map<RegionId, number>();
  for (const line of lines) counts.set(line.region, (counts.get(line.region) ?? 0) + 1);
  return [...counts.entries()].map(([region, count]) => ({ region, lines: count }));
}

// MARK: - Key words

export interface WordMatch {
  /** 1-based line of the `case` in the expansion. */
  line: number;
  /** The byte count the `where` clause checks. */
  count: number;
  words: { offset: number; literal: string; bytes: number[] }[];
  /** The key the words spell: the first `count` bytes, as UTF-8. */
  key: string;
}

const CASE = /case (0x[0-9A-Fa-f_]+) where \w+(?:\.count)? == (\d+)((?:\s*&&\s*\w+\.paddedWord\(at: \d+\) == 0x[0-9A-Fa-f_]+)*)/;
const LATER = /paddedWord\(at: (\d+)\) == (0x[0-9A-Fa-f_]+)/g;

/** The eight bytes of a padded word, lowest address first: the literal is little-endian. */
export function wordBytes(literal: string): number[] {
  const hex = literal.replace(/^0x/, "").replaceAll("_", "").padStart(16, "0");
  const bytes: number[] = [];
  for (let i = 0; i < 8; i++) {
    const at = 16 - (i + 1) * 2;
    bytes.push(parseInt(hex.slice(at, at + 2), 16));
  }
  return bytes;
}

/**
 * Every word comparison the generated matcher makes, decoded back to the key it spells. The
 * generator computed these literals from the keys at compile time; reading them back is how the
 * view shows a key match is a load and a compare rather than a string comparison.
 */
export function decodeWordMatches(expansion: string): WordMatch[] {
  const out: WordMatch[] = [];
  expansion.split("\n").forEach((text, i) => {
    const match = CASE.exec(text);
    if (!match) return;
    const count = Number(match[2]);
    const words = [{ offset: 0, literal: match[1], bytes: wordBytes(match[1]) }];
    for (const later of match[3].matchAll(LATER)) {
      words.push({ offset: Number(later[1]), literal: later[2], bytes: wordBytes(later[2]) });
    }
    const bytes = words.flatMap((w) => w.bytes).slice(0, count);
    out.push({ line: i + 1, count, words, key: new TextDecoder().decode(new Uint8Array(bytes)) });
  });
  return out;
}
