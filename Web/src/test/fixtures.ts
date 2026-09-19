import { vi } from "vitest";
import pipelineJson from "../../content/pipeline.json";
import type { ContentBundle, DocHistory, DocSection, Pipeline, SourceBundle, TraceBundle, Verdict } from "../types";

const files = Object.fromEntries(
  Object.entries(
    import.meta.glob<string>("../../generated/**/*", { query: "?raw", import: "default", eager: true })
  ).map(([path, text]) => [path.replace("../../generated/", ""), text])
);

function generated(name: string): string {
  const text = files[name];
  if (text === undefined) throw new Error(`no generated file ${name}`);
  return text;
}

export const pipeline = pipelineJson as Pipeline;
export const content = JSON.parse(generated("content.json")) as ContentBundle;
export const traces = JSON.parse(generated("traces.json")) as TraceBundle;
export const sources = JSON.parse(generated("sources.json")) as SourceBundle;

export function serveGenerated(fail: (path: string) => boolean = () => false) {
  const fetchStub = vi.fn(async (input: string | URL | Request) => {
    const path = new URL(input instanceof Request ? input.url : input).pathname.slice(1);
    if (fail(path)) return new Response("", { status: 500, statusText: "Server Error" });
    try {
      return new Response(generated(decodeURIComponent(path)), { status: 200 });
    } catch {
      return new Response("", { status: 404, statusText: "Not Found" });
    }
  });
  vi.stubGlobal("fetch", fetchStub);
  return fetchStub;
}

export function section(overrides: Partial<DocSection> & { title: string; verdict?: Verdict }): DocSection {
  return {
    path: overrides.title.toLowerCase().replace(/\W+/g, "-"),
    slug: "",
    level: 3,
    chapter: overrides.title,
    line: 1,
    verdict: "neutral",
    markdown: "",
    summary: "",
    tables: [],
    codeBlocks: [],
    measurements: [],
    ...overrides
  };
}

export function history(recorded: string, revised = recorded, revisions = 1): DocHistory {
  return {
    recorded,
    recordedCommit: "a".repeat(40),
    recordedSubject: "Record it",
    revised,
    revisedCommit: "b".repeat(40),
    revisedSubject: "Revise it",
    revisions
  };
}
