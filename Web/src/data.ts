import type { ContentBundle, SourceBundle, TraceBundle } from "./types";

// Relative to the document, not a base path, so one build works from any host or subpath.
function assetURL(name: string): string {
  return new URL(name, document.baseURI).href;
}

async function json<T>(name: string): Promise<T> {
  const response = await fetch(assetURL(name));
  if (!response.ok) {
    throw new Error(`${name}: ${response.status} ${response.statusText}`);
  }
  return (await response.json()) as T;
}

export const loadContent = () => json<ContentBundle>("content.json");
export const loadTraces = () => json<TraceBundle>("traces.json");

// Only a fulfilled promise is cached, so a failed load can be retried.
let sourcesPromise: Promise<SourceBundle> | null = null;
export function loadSources(): Promise<SourceBundle> {
  sourcesPromise ??= json<SourceBundle>("sources.json").catch((error) => {
    sourcesPromise = null;
    throw error;
  });
  return sourcesPromise;
}

const asmCache = new Map<string, Promise<string>>();
export function loadAssembly(symbol: string): Promise<string> {
  const existing = asmCache.get(symbol);
  if (existing) return existing;

  const pending = fetch(assetURL(`asm/${symbol}.txt`))
    .then((response) => {
      if (!response.ok) {
        throw new Error(
          `No pinned listing for ${symbol} (${response.status}). Run ./Benchmarks/bench build, then ./Web/generate asm.`
        );
      }
      return response.text();
    })
    .catch((error) => {
      asmCache.delete(symbol);
      throw error;
    });

  asmCache.set(symbol, pending);
  return pending;
}
