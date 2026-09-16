import "@testing-library/jest-dom/vitest";
import { cleanup } from "@testing-library/react";
import { afterEach, vi } from "vitest";

// jsdom has no layout, media queries or ResizeObserver; stub just enough for the components.

afterEach(() => {
  cleanup();
  media.clear();
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

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
