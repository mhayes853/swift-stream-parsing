import { useMemo } from "react";

// Syntax highlighting for the three languages the evidence is actually written in: Swift, the C
// of `StreamParsingShims`, and arm64/x86 disassembly.
//
// Hand-written for the same reason the markdown renderer is: a highlighter that ships grammars for
// two hundred languages is more surface area than a site with three. It is also the only way the
// assembly gets highlighted at all — a listing from `llvm-objdump` is not a language any of them
// have a grammar for, and it is the one place here where colour genuinely helps, because picking a
// register out of six hundred lines of operands is the whole activity.
//
// Colour carries nothing the text does not: a keyword is still spelled out, so what governs the
// palette is text contrast rather than the categorical separation the chart lanes need. Every
// token colour clears 4.5:1 against `--surface-2` in both themes; the values and their ratios are
// in `styles.css` next to the variables.
//
// A fence with no language is drawn plain rather than guessed at. Several of the unlabelled ones
// in the log are compiler errors and throughput tables, and a guess would colour them wrong.

type TokenClass =
  | "com"
  | "str"
  | "kw"
  | "num"
  | "type"
  | "attr"
  | "plain"
  | "reg"
  | "addr"
  | "mn"
  | "sym";

interface Token {
  text: string;
  cls: TokenClass;
}

export type Language = "swift" | "c" | "asm" | "text";

/** A fence's info string, mapped onto the three grammars. Anything else draws plain. */
export function languageOf(fence: string | undefined): Language {
  switch ((fence ?? "").toLowerCase()) {
    case "swift":
      return "swift";
    case "c":
    case "h":
    case "objc":
      return "c";
    case "asm":
    case "arm":
    case "arm64":
    case "x86":
      return "asm";
    default:
      return "text";
  }
}

const SWIFT_KEYWORDS = new Set([
  "actor", "any", "as", "associatedtype", "async", "await", "borrowing", "break", "case", "catch",
  "class", "consume", "consuming", "continue", "default", "defer", "deinit", "do", "each", "else",
  "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "get", "guard", "if",
  "import", "in", "indirect", "infix", "init", "inout", "internal", "is", "let", "mutating",
  "nil", "nonisolated", "nonmutating", "open", "operator", "package", "postfix", "precedencegroup",
  "prefix", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "set",
  "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
  "typealias", "unowned", "var", "weak", "where", "while", "willSet", "didSet", "yield"
]);

const C_KEYWORDS = new Set([
  "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
  "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict",
  "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
  "unsigned", "void", "volatile", "while", "_Bool", "_Static_assert"
]);

const IDENT_START = /[A-Za-z_$]/;
const IDENT_BODY = /[A-Za-z0-9_$]/;
const DIGIT = /[0-9]/;

/** Swift, including the pieces this codebase leans on: raw strings, `#if`, and `@_attributes`. */
function swift(code: string): Token[] {
  const out: Token[] = [];
  let i = 0;
  const push = (text: string, cls: TokenClass) => {
    const last = out[out.length - 1];
    if (last && last.cls === cls) last.text += text;
    else out.push({ text, cls });
  };

  while (i < code.length) {
    const c = code[i];

    if (c === "/" && code[i + 1] === "/") {
      const end = code.indexOf("\n", i);
      push(code.slice(i, end === -1 ? code.length : end), "com");
      i = end === -1 ? code.length : end;
      continue;
    }
    // Block comments nest in Swift, so this counts rather than searching for the first `*/`.
    if (c === "/" && code[i + 1] === "*") {
      let depth = 0;
      const start = i;
      while (i < code.length) {
        if (code[i] === "/" && code[i + 1] === "*") { depth += 1; i += 2; continue; }
        if (code[i] === "*" && code[i + 1] === "/") { depth -= 1; i += 2; if (depth === 0) break; continue; }
        i += 1;
      }
      push(code.slice(start, i), "com");
      continue;
    }
    // `#"…"#` and `#"""…"""#`: the escape character is `\#`, so a plain backslash is literal.
    if (c === "#" && (code[i + 1] === "#" || code[i + 1] === '"')) {
      let hashes = 0;
      while (code[i + hashes] === "#") hashes += 1;
      if (code[i + hashes] === '"') {
        const fence = "#".repeat(hashes);
        const triple = code.startsWith('"""', i + hashes);
        const quote = triple ? '"""' : '"';
        const closing = quote + fence;
        const from = i + hashes + quote.length;
        const end = code.indexOf(closing, from);
        const stop = end === -1 ? code.length : end + closing.length;
        push(code.slice(i, stop), "str");
        i = stop;
        continue;
      }
    }
    if (c === '"') {
      const triple = code.startsWith('"""', i);
      const quote = triple ? '"""' : '"';
      let j = i + quote.length;
      while (j < code.length) {
        if (code[j] === "\\") { j += 2; continue; }
        if (code.startsWith(quote, j)) { j += quote.length; break; }
        if (!triple && code[j] === "\n") break;
        j += 1;
      }
      push(code.slice(i, j), "str");
      i = j;
      continue;
    }
    // `@inline(__always)` and `#if compiler(>=6.2)` read as one mark on the declaration.
    if (c === "@" || (c === "#" && IDENT_START.test(code[i + 1] ?? ""))) {
      let j = i + 1;
      while (j < code.length && IDENT_BODY.test(code[j])) j += 1;
      push(code.slice(i, j), "attr");
      i = j;
      continue;
    }
    if (DIGIT.test(c) || (c === "." && DIGIT.test(code[i + 1] ?? ""))) {
      let j = i;
      while (j < code.length && /[0-9a-fA-FxXoObB_.]/.test(code[j])) {
        // An exponent's sign is part of the literal; a `.` that starts a member access is not.
        if (code[j] === "." && !DIGIT.test(code[j + 1] ?? "")) break;
        j += 1;
      }
      if ((code[j] === "e" || code[j] === "E" || code[j] === "p" || code[j] === "P")
        && /[-+0-9]/.test(code[j + 1] ?? "")) {
        j += 2;
        while (j < code.length && DIGIT.test(code[j])) j += 1;
      }
      push(code.slice(i, j), "num");
      i = j;
      continue;
    }
    if (IDENT_START.test(c)) {
      let j = i;
      while (j < code.length && IDENT_BODY.test(code[j])) j += 1;
      const word = code.slice(i, j);
      push(word, SWIFT_KEYWORDS.has(word) ? "kw" : /^[A-Z]/.test(word) ? "type" : "plain");
      i = j;
      continue;
    }
    push(c, "plain");
    i += 1;
  }
  return out;
}

/** C, with the shim's uppercase macros treated the way Swift's attributes are. */
function cLanguage(code: string): Token[] {
  const out: Token[] = [];
  let i = 0;
  let atLineStart = true;
  const push = (text: string, cls: TokenClass) => {
    const last = out[out.length - 1];
    if (last && last.cls === cls) last.text += text;
    else out.push({ text, cls });
  };

  while (i < code.length) {
    const c = code[i];
    if (c === "\n") { push(c, "plain"); atLineStart = true; i += 1; continue; }

    if (c === "/" && code[i + 1] === "/") {
      const end = code.indexOf("\n", i);
      push(code.slice(i, end === -1 ? code.length : end), "com");
      i = end === -1 ? code.length : end;
      continue;
    }
    if (c === "/" && code[i + 1] === "*") {
      const end = code.indexOf("*/", i + 2);
      const stop = end === -1 ? code.length : end + 2;
      push(code.slice(i, stop), "com");
      i = stop;
      continue;
    }
    // A directive runs to the end of the line, continuations included.
    if (c === "#" && atLineStart) {
      let j = i;
      while (j < code.length) {
        const end = code.indexOf("\n", j);
        if (end === -1) { j = code.length; break; }
        if (code[end - 1] !== "\\") { j = end; break; }
        j = end + 1;
      }
      push(code.slice(i, j), "attr");
      i = j;
      continue;
    }
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < code.length && code[j] !== c && code[j] !== "\n") {
        j += code[j] === "\\" ? 2 : 1;
      }
      push(code.slice(i, Math.min(j + 1, code.length)), "str");
      i = Math.min(j + 1, code.length);
      continue;
    }
    if (DIGIT.test(c)) {
      let j = i;
      while (j < code.length && /[0-9a-fA-FxXuUlL.]/.test(code[j])) j += 1;
      push(code.slice(i, j), "num");
      i = j;
      continue;
    }
    if (IDENT_START.test(c)) {
      let j = i;
      while (j < code.length && IDENT_BODY.test(code[j])) j += 1;
      const word = code.slice(i, j);
      const cls: TokenClass = C_KEYWORDS.has(word)
        ? "kw"
        : /^[A-Z0-9_]+$/.test(word) && word.length > 2
          ? "attr"
          : word.endsWith("_t") || /^[A-Z]/.test(word)
            ? "type"
            : "plain";
      push(word, cls);
      i = j;
      continue;
    }
    if (!/\s/.test(c)) atLineStart = false;
    push(c, "plain");
    i += 1;
  }
  return out;
}

// `100210080:` from a pinned listing, and the colon-less `be3a0` the log quotes inline. A word
// has to be four hex digits before it counts, which is what keeps `before` and `after` out.
const ASM_ADDRESS = /^\s*[0-9a-f]{4,16}:?(?=\s)/;
const REGISTER = /^(?:[xwqvdshb]\d+|%[a-z0-9]+|sp|lr|pc|wzr|xzr|fp)(?:\.\d*[a-z]+)?$/i;

/**
 * A pinned `llvm-objdump` listing.
 *
 * Line oriented, because that is what the format is: a `;` header the extractor wrote, then
 * address, mnemonic, operands, and a `<symbol+0x…>` on anything that branches. The mnemonic is
 * marked separately from its operands so a scan down the left edge reads as the instruction
 * sequence, which is how these listings actually get read.
 */
function asm(code: string): Token[] {
  const out: Token[] = [];
  for (const line of code.split("\n")) {
    if (line.trimStart().startsWith(";")) {
      out.push({ text: line + "\n", cls: "com" });
      continue;
    }
    let rest = line;
    const address = ASM_ADDRESS.exec(line);
    if (address) {
      out.push({ text: address[0], cls: "addr" });
      rest = line.slice(address[0].length);
    }
    // A trailing `; …` is a note the log wrote next to an instruction, not an operand.
    let note = "";
    const semicolon = rest.indexOf(";");
    if (semicolon !== -1) {
      note = rest.slice(semicolon);
      rest = rest.slice(0, semicolon);
    }
    // The first word of the instruction is the mnemonic; everything after it is operands.
    const mnemonic = /^(\s*)([a-z][a-z0-9._]*)(?=\s|$)/.exec(rest);
    if (mnemonic) {
      out.push({ text: mnemonic[1], cls: "plain" });
      out.push({ text: mnemonic[2], cls: "mn" });
      rest = rest.slice(mnemonic[0].length);
    }
    for (const piece of rest.split(/(<[^>]*>|[^\s,[\]{}()]+|.)/g)) {
      if (!piece) continue;
      if (piece.startsWith("<")) out.push({ text: piece, cls: "sym" });
      else if (/^[#$]?-?0x[0-9a-f]+$/i.test(piece) || /^#-?\d+$/.test(piece)) {
        out.push({ text: piece, cls: "num" });
      } else if (REGISTER.test(piece)) out.push({ text: piece, cls: "reg" });
      else out.push({ text: piece, cls: "plain" });
    }
    if (note) out.push({ text: note, cls: "com" });
    out.push({ text: "\n", cls: "plain" });
  }
  if (out.length > 0) out[out.length - 1].text = out[out.length - 1].text.replace(/\n$/, "");
  return out;
}

export function tokenize(code: string, language: Language): Token[] {
  switch (language) {
    case "swift":
      return swift(code);
    case "c":
      return cLanguage(code);
    case "asm":
      return asm(code);
    default:
      return [{ text: code, cls: "plain" }];
  }
}

/** A highlighted block. `text` draws exactly as before, one span, no classes. */
export function Code({
  children,
  language,
  style
}: {
  children: string;
  language: Language;
  style?: React.CSSProperties;
}) {
  // Memoised on the text: an assembly listing is six hundred lines and the panel re-renders on
  // every tab change.
  const tokens = useMemo(() => tokenize(children, language), [children, language]);
  return (
    <pre style={style}>
      <code className={`hl hl-${language}`}>
        {tokens.map((token, i) =>
          token.cls === "plain" ? (
            token.text
          ) : (
            <span key={i} className={`t-${token.cls}`}>
              {token.text}
            </span>
          )
        )}
      </code>
    </pre>
  );
}
