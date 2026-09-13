import type { ReactNode } from "react";
import { cx } from "../lib/cx";
import { languageOf } from "../lib/highlight";
import { parseBlocks, parseTable, tokenizeInline } from "../lib/markdown";
import type { Verdict } from "../types";
import { Code } from "./highlight";

/** Inline markdown — code, bold, emphasis, links — as React nodes. */
export function inline(text: string, keyPrefix = "i"): ReactNode[] {
  return tokenizeInline(text).map((token, i) => {
    const key = `${keyPrefix}-${i}`;
    switch (token.kind) {
      case "text":
        return token.text;
      case "code":
        return <code key={key}>{token.text}</code>;
      case "strong":
        return <strong key={key}>{token.text}</strong>;
      case "em":
        return <em key={key}>{token.text}</em>;
      case "link":
        return (
          <a key={key} href={token.href} target="_blank" rel="noreferrer">
            {token.text}
          </a>
        );
    }
  });
}

/** A markdown table, right-aligning numeric columns and colouring signed deltas. */
function MarkdownTable({ rows }: { rows: string[] }) {
  const table = parseTable(rows);
  // Wrapped so a wide table scrolls inside its own box. Reflowing a measurement table would break
  // its columns apart, and letting it overflow widens the whole panel on a phone.
  return (
    <div className="table-scroll">
      <table>
        <thead>
          <tr>
            {table.headers.map((header, i) => (
              <th key={i}>{inline(header, `h${i}`)}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {table.rows.map((row, r) => (
            <tr key={r}>
              {row.map((cell, c) => (
                <td
                  key={c}
                  className={cx(cell.numeric && "num", cell.strong && "strong", cell.delta && `delta ${cell.delta}`)}
                >
                  {inline(cell.text, `c${r}-${c}`)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Markdown({ children }: { children: string }) {
  return (
    <div className="md">
      {parseBlocks(children).map((block, i) => {
        switch (block.kind) {
          case "code":
            return (
              <Code key={i} language={languageOf(block.language)}>
                {block.code}
              </Code>
            );
          case "table":
            return <MarkdownTable key={i} rows={block.rows} />;
          case "ul":
            return (
              <ul key={i}>
                {block.items.map((item, j) => (
                  <li key={j}>{inline(item, `${i}-${j}`)}</li>
                ))}
              </ul>
            );
          case "quote":
            return <blockquote key={i}>{inline(block.text, `q${i}`)}</blockquote>;
          case "p":
            return <p key={i}>{inline(block.text, `p${i}`)}</p>;
        }
      })}
    </div>
  );
}

const VERDICT_LABEL: Record<Verdict, string> = {
  landed: "Landed",
  rejected: "Rejected",
  mixed: "Mixed",
  neutral: "Context"
};

export function VerdictChip({ verdict }: { verdict: Verdict }) {
  // The written word is always present: the status hue never carries the meaning on its own.
  return <span className={`verdict ${verdict}`}>{VERDICT_LABEL[verdict]}</span>;
}
