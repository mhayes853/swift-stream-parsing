import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { loadContent, loadLibrary, loadSources, loadTraces } from "../data";
import { formatRoute, parseRoute, type Route } from "../lib/route";
import type { ContentBundle, LibraryBundle, SourceDecl, TraceBundle } from "../types";

export function useInnerWidth<T extends HTMLElement>(initial: number) {
  const ref = useRef<T>(null);
  const [width, setWidth] = useState(initial);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => {
      const style = getComputedStyle(el);
      const inner = el.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
      if (inner > 0) setWidth(inner);
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);
  return [ref, width] as const;
}

export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => window.matchMedia(query).matches);
  useEffect(() => {
    const media = window.matchMedia(query);
    const update = () => setMatches(media.matches);
    update();
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  }, [query]);
  return matches;
}

export function useEscape(action: () => void) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") action();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [action]);
}

export function useBundles() {
  const [content, setContent] = useState<ContentBundle | null>(null);
  const [traces, setTraces] = useState<TraceBundle | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    loadContent().then(setContent, (e) => setError(String(e)));
    loadTraces().then(setTraces, (e) => setError(String(e)));
  }, []);
  return { content, traces, error };
}

export function useTheme() {
  const [theme, setTheme] = useState(() => document.documentElement.dataset.theme ?? "dark");
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
  }, [theme]);
  const toggle = useCallback(() => setTheme((t) => (t === "dark" ? "light" : "dark")), []);
  return [theme, toggle] as const;
}

export function useRoute(nodeIds: ReadonlySet<string>) {
  const read = useCallback(() => parseRoute(window.location.hash, nodeIds), [nodeIds]);
  const [route, setRoute] = useState(read);

  useEffect(() => {
    const sync = () => setRoute(read());
    window.addEventListener("popstate", sync);
    window.addEventListener("hashchange", sync);
    return () => {
      window.removeEventListener("popstate", sync);
      window.removeEventListener("hashchange", sync);
    };
  }, [read]);

  const go = useCallback((next: Route) => {
    const hash = formatRoute(next);
    if (hash === window.location.hash) return;
    // Marked so closing a panel this page opened steps back rather than pushing another entry.
    window.history.pushState({ opened: next.node !== null }, "", hash);
    setRoute(next);
  }, []);

  const closeNode = useCallback(() => {
    if (window.history.state?.opened) {
      window.history.back();
    } else {
      window.history.replaceState(null, "", formatRoute({ view: "flow", node: null }));
      setRoute({ view: "flow", node: null });
    }
  }, []);

  return { route, go, closeNode };
}

export interface Sources {
  value: Record<string, SourceDecl[]> | null;
  error: string | null;
}

/** The declaration bodies, fetched the first time something asks for them. */
export function useSources(): Sources {
  const [sources, setSources] = useState<Sources>({ value: null, error: null });
  useEffect(() => {
    loadSources().then(
      (bundle) => setSources({ value: bundle.sources, error: null }),
      (e) => setSources({ value: null, error: String(e) })
    );
  }, []);
  return sources;
}

/** `library.json`, for the Tests and Macros views; fetched when one of them is first opened. */
export function useLibrary(enabled: boolean): { library: LibraryBundle | null; error: string | null } {
  const [state, setState] = useState<{ library: LibraryBundle | null; error: string | null }>({
    library: null,
    error: null
  });
  useEffect(() => {
    if (!enabled) return;
    loadLibrary().then(
      (library) => setState({ library, error: null }),
      (e) => setState({ library: null, error: String(e) })
    );
  }, [enabled]);
  return state;
}
