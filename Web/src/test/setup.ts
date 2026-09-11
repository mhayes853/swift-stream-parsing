import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, vi } from "vitest";

// jsdom has no layout, no media queries and no resize observation. The components only need these
// to exist: widths fall back to each chart's default, and every media query is answered by `media`
// below, which a test can change.

afterEach(() => {
  cleanup();
  media.clear();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

/** Media queries a test wants to match. Anything not listed does not match. */
export const media = new Set<string>();

window.matchMedia = (query: string) =>
  ({
    matches: media.has(query),
    media: query,
    onchange: null,
    addEventListener: () => {},
    removeEventListener: () => {},
    addListener: () => {},
    removeListener: () => {},
    dispatchEvent: () => false
  }) as MediaQueryList;

globalThis.ResizeObserver = class {
  observe() {}
  unobserve() {}
  disconnect() {}
};

window.scrollTo = () => {};
