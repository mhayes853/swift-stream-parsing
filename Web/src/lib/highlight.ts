export type TokenClass =
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

export interface Token {
  text: string;
  cls: TokenClass;
}

function collector() {
  const out: Token[] = [];
  const push = (text: string, cls: TokenClass) => {
    const last = out[out.length - 1];
    if (last && last.cls === cls) last.text += text;
    else out.push({ text, cls });
  };
  return { out, push };
}

export type Language = "swift" | "c" | "asm" | "text";

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

function swift(code: string): Token[] {
  const { out, push } = collector();
  let i = 0;

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
    if (c === "@" || (c === "#" && IDENT_START.test(code[i + 1] ?? ""))) {
      let j = i + 1;
      while (j < code.length && IDENT_BODY.test(code[j])) j += 1;
      push(code.slice(i, j), "attr");
      i = j;
      continue;
    }
    if (DIGIT.test(c) || (c === "." && DIGIT.test(code[i + 1] ?? ""))) {
      let j = i;
      // Hex digits only after `0x`, or the `e` in `1.5e-3` is read as a digit.
      const hex = c === "0" && /[xX]/.test(code[i + 1] ?? "");
      const body = hex ? /[0-9a-fA-FxX_.]/ : /[0-9oObB_.]/;
      while (j < code.length && body.test(code[j])) {
        if (code[j] === "." && !DIGIT.test(code[j + 1] ?? "")) break;
        j += 1;
      }
      const exponent = hex ? /[pP]/ : /[eE]/;
      if (exponent.test(code[j] ?? "") && /[-+0-9]/.test(code[j + 1] ?? "")) {
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

function cLanguage(code: string): Token[] {
  const { out, push } = collector();
  let i = 0;
  let atLineStart = true;

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

// At least four hex digits, so words like `before` are not addresses.
const ASM_ADDRESS = /^\s*[0-9a-f]{4,16}:?(?=\s)/;
const REGISTER = /^(?:[xwqvdshb]\d+|%[a-z0-9]+|sp|lr|pc|wzr|xzr|fp)(?:\.\d*[a-z]+)?$/i;

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
    let note = "";
    const semicolon = rest.indexOf(";");
    if (semicolon !== -1) {
      note = rest.slice(semicolon);
      rest = rest.slice(0, semicolon);
    }
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
