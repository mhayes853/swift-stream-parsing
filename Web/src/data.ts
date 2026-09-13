import type { ContentBundle, SourceBundle, TraceBundle } from "./types";

// The generated bundles are served as static files beside index.html (vite `publicDir:
// "generated"`), not bundled into the JS: content.json alone is 1.7 MB.
//
// They are addressed **relative to the document**, not to a configured base path. A hard-coded
// absolute base only resolves when the site is served from that exact prefix, so a build made for
// a GitHub Pages subpath 404s everything the moment it is opened from a local static server, a
// preview host, or a different repository name. `document.baseURI` is whatever the page was
// actually loaded from, so the same build works from all of them.
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

/**
 * Deferred until a Source tab is opened, then shared by every later one.
 *
 * Only a *fulfilled* promise is cached. Memoizing the rejection too would mean one transient
 * failure leaves the Source tab permanently broken for the rest of the session with no way to
 * retry, which is precisely the case a reader hits and cannot diagnose.
 */
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
