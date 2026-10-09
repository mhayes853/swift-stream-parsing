import type { DocSection, Verdict } from "../types";
import { instant } from "./dates";
import { flatten } from "./markdown";

const LEAD = 70;
const TRAIL = 130;

export interface Indexed {
  section: DocSection;
  body: string;
  bodyLower: string;
  titleLower: string;
  summaryLower: string;
}

export interface Hit {
  section: DocSection;
  where: "title" | "summary" | "body";
  snippet?: { before: string; match: string; after: string };
  count: number;
}

export function buildIndex(sections: DocSection[]): Indexed[] {
  return sections.map((section) => {
    const body = flatten(`${section.title}\n${section.chapter}\n${section.summary}\n${section.markdown}`);
    return {
      section,
      body,
      bodyLower: body.toLowerCase(),
      titleLower: section.title.toLowerCase(),
      summaryLower: `${section.summary}\n${section.chapter}`.toLowerCase()
    };
  });
}

export function parseQuery(query: string): string[] {
  return query.trim().toLowerCase().split(/\s+/).filter(Boolean);
}

export function matches(entry: Indexed, terms: string[]): boolean {
  return terms.every((t) => entry.bodyLower.includes(t));
}

export function hit(entry: Indexed, terms: string[]): Hit {
  const { section } = entry;
  if (terms.every((t) => entry.titleLower.includes(t))) return { section, where: "title", count: 0 };
  if (terms.every((t) => entry.summaryLower.includes(t))) return { section, where: "summary", count: 0 };

  const term = terms.find((t) => entry.bodyLower.includes(t)) ?? terms[0];
  const at = entry.bodyLower.indexOf(term);
  const count = occurrences(entry.bodyLower, term);

  let from = Math.max(0, at - LEAD);
  if (from > 0) {
    const space = entry.body.indexOf(" ", from);
    if (space >= 0 && space < at) from = space + 1;
  }
  let to = Math.min(entry.body.length, at + term.length + TRAIL);
  if (to < entry.body.length) {
    const space = entry.body.lastIndexOf(" ", to);
    if (space > at + term.length) to = space;
  }

  return {
    section,
    where: "body",
    count,
    snippet: {
      before: (from > 0 ? "…" : "") + entry.body.slice(from, at),
      match: entry.body.slice(at, at + term.length),
      after: entry.body.slice(at + term.length, to) + (to < entry.body.length ? "…" : "")
    }
  };
}

function occurrences(text: string, term: string): number {
  let count = 0;
  for (let i = text.indexOf(term); i >= 0; i = text.indexOf(term, i + term.length)) count++;
  return count;
}

export interface SearchResult {
  hits: Hit[];
  hidden: number;
}

export function search(
  index: Indexed[],
  terms: string[],
  verdict: Verdict | "all",
  oldestFirst = false
): SearchResult {
  const found = terms.length === 0 ? index : index.filter((e) => matches(e, terms));
  const hits = found
    .filter((e) => verdict === "all" || e.section.verdict === verdict)
    .map((e): Hit => (terms.length === 0 ? { section: e.section, where: "title", count: 0 } : hit(e, terms)))
    .sort((a, b) => {
      const d = instant(a.section.history?.recorded) - instant(b.section.history?.recorded);
      return oldestFirst ? d : -d;
    });
  return { hits, hidden: found.length - hits.length };
}

export function markTerms(text: string, terms: string[]): { text: string; marked: boolean }[] {
  const lower = text.toLowerCase();
  const out: { text: string; marked: boolean }[] = [];
  let at = 0;
  while (at < text.length) {
    let best = -1;
    let length = 0;
    for (const t of terms) {
      const found = lower.indexOf(t, at);
      if (found >= 0 && (best < 0 || found < best)) {
        best = found;
        length = t.length;
      }
    }
    if (best < 0) break;
    if (best > at) out.push({ text: text.slice(at, best), marked: false });
    out.push({ text: text.slice(best, best + length), marked: true });
    at = best + length;
  }
  if (at < text.length) out.push({ text: text.slice(at), marked: false });
  return out;
}
