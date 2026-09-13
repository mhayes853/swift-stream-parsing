// A deliberately small parser for the subset NEW_ARCHITECTURE.md actually uses: paragraphs, fenced
// code, tables, bullet lists, block quotes and inline emphasis. Pulling in a markdown library to
// render one authored document would be more surface area than the document has features.
//
// Parsing and rendering are separate so the grammar can be tested without a DOM: this file turns
// text into blocks and tokens, and `components/Markdown.tsx` draws them.

export type InlineToken =
  | { kind: "text" | "code" | "strong" | "em"; text: string }
  | { kind: "link"; text: string; href: string };

// `code` first so emphasis markers inside a span of code are left alone, and `**` before `*` so a
// bold run is not read as two empty emphases. The single-star form is the one the log reaches for
// most (221 occurrences against 642 bold ones) and it used to render as literal asterisks, which
// is the one way a renderer can be worse than no renderer.
const INLINE = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*\n]+\*)|(\[[^\]]+\]\([^)]+\))/g;

export function tokenizeInline(text: string): InlineToken[] {
  const out: InlineToken[] = [];
  let last = 0;
  for (const match of text.matchAll(INLINE)) {
    const token = match[0];
    if (match.index > last) out.push({ kind: "text", text: text.slice(last, match.index) });
    if (match[1]) out.push({ kind: "code", text: token.slice(1, -1) });
    else if (match[2]) out.push({ kind: "strong", text: token.slice(2, -2) });
    else if (match[3]) out.push({ kind: "em", text: token.slice(1, -1) });
    else {
      const split = token.indexOf("](");
      out.push({ kind: "link", text: token.slice(1, split), href: token.slice(split + 2, -1) });
    }
    last = match.index + token.length;
  }
  if (last < text.length) out.push({ kind: "text", text: text.slice(last) });
  return out;
}

export type Block =
  | { kind: "p" | "quote"; text: string }
  | { kind: "code"; code: string; language: string }
  | { kind: "ul"; items: string[] }
  | { kind: "table"; rows: string[] };

const isFence = (l: string) => l.startsWith("```");
const isTableRow = (l: string) => l.trimStart().startsWith("|");
const isQuote = (l: string) => l.startsWith(">");
const BULLET = /^\s*[-*]\s/;
const isBullet = (l: string) => BULLET.test(l);

export function parseBlocks(markdown: string): Block[] {
  const out: Block[] = [];
  const lines = markdown.split("\n");
  let i = 0;
  /** The run of lines from `i` that satisfy `test`, consumed. */
  const run = (test: (line: string) => boolean) => {
    const body: string[] = [];
    while (i < lines.length && test(lines[i])) body.push(lines[i++]);
    return body;
  };

  while (i < lines.length) {
    const line = lines[i];
    if (isFence(line)) {
      i++;
      const code = run((l) => !isFence(l)).join("\n");
      i++; // the closing fence
      out.push({ kind: "code", code, language: line.slice(3).trim() });
    } else if (!line.trim()) {
      i++;
    } else if (isTableRow(line)) {
      out.push({ kind: "table", rows: run(isTableRow) });
    } else if (isBullet(line)) {
      // A wrapped bullet is an indented line that continues the previous item.
      const items: string[] = [];
      for (const l of run((l) => isBullet(l) || (l.startsWith("  ") && !!l.trim()))) {
        if (isBullet(l)) items.push(l.replace(BULLET, ""));
        else items[items.length - 1] += " " + l.trim();
      }
      out.push({ kind: "ul", items });
    } else if (isQuote(line)) {
      out.push({ kind: "quote", text: run(isQuote).map((l) => l.replace(/^>\s?/, "")).join(" ") });
    } else {
      const body = run(
        (l) => !!l.trim() && !isTableRow(l) && !isBullet(l) && !isFence(l) && !isQuote(l)
      );
      out.push({ kind: "p", text: body.join(" ") });
    }
  }
  return out;
}

export interface TableCell {
  text: string;
  /** A number in a column past the label column, right-aligned in tabular figures. */
  numeric: boolean;
  /** The whole cell was bold in the source — usually the row a result is about. */
  strong: boolean;
  /** A signed percentage, which is drawn in the diverging pair by its sign. */
  delta: "pos" | "neg" | null;
}

export interface Table {
  headers: string[];
  rows: TableCell[][];
}

function splitRow(line: string): string[] {
  let t = line.trim();
  if (t.startsWith("|")) t = t.slice(1);
  if (t.endsWith("|")) t = t.slice(0, -1);
  return t.split("|").map((c) => c.trim());
}

const SEPARATOR = /^:?-{2,}:?$/;

export function parseTable(rows: string[]): Table {
  const headers = splitRow(rows[0]);
  const hasSeparator = SEPARATOR.test(splitRow(rows[1] ?? "")[0] ?? "");
  return {
    headers,
    rows: rows.slice(hasSeparator ? 2 : 1).map((row) =>
      splitRow(row).map((text, column) => {
        const plain = text.replace(/\*\*/g, "").replace(/`/g, "").trim();
        const negative = plain.startsWith("-") || plain.startsWith("−");
        return {
          text,
          numeric: column > 0 && /^[+−-]?[\d.,]+/.test(plain),
          strong: text.includes("**"),
          delta: /^[+−-]\d/.test(plain) && plain.includes("%") ? (negative ? "neg" : "pos") : null
        };
      })
    )
  };
}

/**
 * The text a reader sees, on one line: fences, link targets and emphasis marks removed. Used by the
 * search, so an excerpt reads as prose rather than as source and a query can span a span of code —
 * "shrn movemask" is two words in the log with a backtick between them.
 */
export function flatten(markdown: string): string {
  return markdown
    .replace(/```[a-z]*\n?/g, "")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/[`*#>]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}
