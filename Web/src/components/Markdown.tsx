import { Fragment, type ReactNode } from "react";
import { Code, languageOf } from "./highlight";

// A deliberately small block renderer for the subset NEW_ARCHITECTURE.md actually uses:
// paragraphs, fenced code, tables, bullet lists, block quotes and inline emphasis. Pulling in a
// markdown library to render one authored document would be more surface area than the document
// has features.

export function inline(text: string, keyPrefix: string): ReactNode[] {
  const out: ReactNode[] = [];
  // `code` first so emphasis markers inside a span of code are left alone.
  const pattern = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\[[^\]]+\]\([^)]+\))/g;
  let last = 0;
  let match: RegExpExecArray | null;
  let index = 0;

  while ((match = pattern.exec(text)) !== null) {
    if (match.index > last) out.push(text.slice(last, match.index));
    const token = match[0];
    const key = `${keyPrefix}-${index++}`;
    if (token.startsWith("`")) {
      out.push(<code key={key}>{token.slice(1, -1)}</code>);
    } else if (token.startsWith("**")) {
      out.push(<strong key={key}>{token.slice(2, -2)}</strong>);
    } else {
      const split = token.indexOf("](");
      const label = token.slice(1, split);
      const href = token.slice(split + 2, -1);
      out.push(
        <a key={key} href={href} target="_blank" rel="noreferrer">
          {label}
        </a>
      );
    }
    last = match.index + token.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

interface Block {
  kind: "p" | "code" | "table" | "ul" | "quote";
  lines: string[];
  language?: string;
}

function blocks(markdown: string): Block[] {
  const out: Block[] = [];
  const lines = markdown.split("\n");
  let i = 0;

  const isTableRow = (l: string) => l.trimStart().startsWith("|");
  const isBullet = (l: string) => /^\s*[-*]\s/.test(l);

  while (i < lines.length) {
    const line = lines[i];

    if (line.startsWith("```")) {
      const language = line.slice(3).trim();
      const body: string[] = [];
      i++;
      while (i < lines.length && !lines[i].startsWith("```")) body.push(lines[i++]);
      i++;
      out.push({ kind: "code", lines: body, language });
      continue;
    }
    if (!line.trim()) {
      i++;
      continue;
    }
    if (isTableRow(line)) {
      const body: string[] = [];
      while (i < lines.length && isTableRow(lines[i])) body.push(lines[i++]);
      out.push({ kind: "table", lines: body });
      continue;
    }
    if (isBullet(line)) {
      const body: string[] = [];
      while (i < lines.length && (isBullet(lines[i]) || (lines[i].startsWith("  ") && lines[i].trim()))) {
        // A wrapped bullet continues the previous item rather than starting one.
        if (isBullet(lines[i])) body.push(lines[i].replace(/^\s*[-*]\s/, ""));
        else body[body.length - 1] += " " + lines[i].trim();
        i++;
      }
      out.push({ kind: "ul", lines: body });
      continue;
    }
    if (line.startsWith(">")) {
      const body: string[] = [];
      while (i < lines.length && lines[i].startsWith(">")) body.push(lines[i++].replace(/^>\s?/, ""));
      out.push({ kind: "quote", lines: body });
      continue;
    }
    const body: string[] = [];
    while (
      i < lines.length &&
      lines[i].trim() &&
      !isTableRow(lines[i]) &&
      !isBullet(lines[i]) &&
      !lines[i].startsWith("```") &&
      !lines[i].startsWith(">")
    ) {
      body.push(lines[i++]);
    }
    out.push({ kind: "p", lines: body });
  }
  return out;
}

function splitRow(line: string): string[] {
  let t = line.trim();
  if (t.startsWith("|")) t = t.slice(1);
  if (t.endsWith("|")) t = t.slice(0, -1);
  return t.split("|").map((c) => c.trim());
}

const SEPARATOR = /^:?-{2,}:?$/;

/** Renders a markdown table, right-aligning numeric columns and colouring signed deltas. */
function MarkdownTable({ rows }: { rows: string[] }) {
  const headers = splitRow(rows[0]);
  const bodyRows = rows.slice(SEPARATOR.test(splitRow(rows[1])[0] ?? "") ? 2 : 1).map(splitRow);

  return (
    <table>
      <thead>
        <tr>
          {headers.map((h, i) => (
            <th key={i}>{inline(h, `h${i}`)}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {bodyRows.map((row, r) => (
          <tr key={r}>
            {row.map((cell, c) => {
              const plain = cell.replace(/\*\*/g, "").replace(/`/g, "").trim();
              const delta = /^[+−-]\d/.test(plain) && plain.includes("%");
              const numeric = /^[+−-]?[\d.,]+/.test(plain) && c > 0;
              const negative = plain.startsWith("-") || plain.startsWith("−");
              return (
                <td
                  key={c}
                  className={[
                    numeric ? "num" : "",
                    cell.includes("**") ? "strong" : "",
                    delta ? `delta ${negative ? "neg" : "pos"}` : ""
                  ]
                    .filter(Boolean)
                    .join(" ")}
                >
                  {inline(cell, `c${r}-${c}`)}
                </td>
              );
            })}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export function Markdown({ children }: { children: string }) {
  return (
    <div className="md">
      {blocks(children).map((block, i) => {
        switch (block.kind) {
          case "code":
            return (
              <Code key={i} language={languageOf(block.language)}>
                {block.lines.join("\n")}
              </Code>
            );
          case "table":
            return <MarkdownTable key={i} rows={block.lines} />;
          case "ul":
            return (
              <ul key={i}>
                {block.lines.map((item, j) => (
                  <li key={j}>{inline(item, `${i}-${j}`)}</li>
                ))}
              </ul>
            );
          case "quote":
            return <blockquote key={i}>{inline(block.lines.join(" "), `q${i}`)}</blockquote>;
          default:
            return <p key={i}>{inline(block.lines.join(" "), `p${i}`)}</p>;
        }
      })}
    </div>
  );
}

export function VerdictChip({ verdict }: { verdict: string }) {
  const label =
    verdict === "landed"
      ? "Landed"
      : verdict === "rejected"
        ? "Rejected"
        : verdict === "mixed"
          ? "Mixed"
          : "Context";
  // The written word is always present: the status hue never carries the meaning on its own.
  return <span className={`verdict ${verdict}`}>{label}</span>;
}

export const Fragments = Fragment;
