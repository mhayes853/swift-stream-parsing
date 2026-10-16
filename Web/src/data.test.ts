import { beforeEach, describe, expect, it, vi } from "vitest";
import { serveGenerated } from "./test/fixtures";

// The loaders cache module-wide, so each test gets a fresh copy of the module.
let data: typeof import("./data");
beforeEach(async () => {
  vi.resetModules();
  data = await import("./data");
});

describe("loadContent", () => {
  it("fetches the bundle relative to the document", async () => {
    const fetch = serveGenerated();
    const content = await data.loadContent();
    expect(content.doc.sections.length).toBeGreaterThan(0);
    expect(String(fetch.mock.calls[0][0])).toBe(new URL("content.json", document.baseURI).href);
  });

  it("says which file failed and how", async () => {
    serveGenerated((path) => path === "content.json");
    await expect(data.loadContent()).rejects.toThrow("content.json: 500 Server Error");
  });
});

describe("loadSources", () => {
  it("fetches once and shares the result", async () => {
    const fetch = serveGenerated();
    await data.loadSources();
    await data.loadSources();
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("does not cache a failure, so the next Source tab retries", async () => {
    let failing = true;
    const fetch = serveGenerated(() => failing);
    await expect(data.loadSources()).rejects.toThrow();
    failing = false;
    await expect(data.loadSources()).resolves.toHaveProperty("sources");
    expect(fetch).toHaveBeenCalledTimes(2);
  });
});

describe("loadAssembly", () => {
  it("loads a pinned listing and caches it by symbol", async () => {
    const fetch = serveGenerated();
    const symbol = Object.keys(import.meta.glob("../generated/asm/*.txt"))[0].replace(/^.*\/(.*)\.txt$/, "$1");
    const listing = await data.loadAssembly(symbol);
    expect(listing.length).toBeGreaterThan(0);
    await data.loadAssembly(symbol);
    expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("explains how to pin a listing that is missing, and retries next time", async () => {
    const fetch = serveGenerated();
    await expect(data.loadAssembly("nothing")).rejects.toThrow("./Web/generate asm");
    await expect(data.loadAssembly("nothing")).rejects.toThrow();
    expect(fetch).toHaveBeenCalledTimes(2);
  });
});
