import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { App } from "./App";
import { citations } from "./lib/overview";
import { content, pipeline, serveGenerated } from "./test/fixtures";

describe("App", () => {
  it("loads the bundles and draws the parse path with the log's numbers", async () => {
    serveGenerated();
    render(<App />);
    expect(screen.getByRole("heading", { name: "The parse path" })).toBeInTheDocument();
    expect(await screen.findByText(String(content.stats.sectionCount))).toBeInTheDocument();
    expect(screen.getByText(String(pipeline.nodes.length))).toBeInTheDocument();
  });

  it("explains how the algorithm works and why, and its citations open the step", async () => {
    const user = userEvent.setup();
    serveGenerated();
    render(<App />);
    expect(screen.getByRole("heading", { name: "How it works" })).toBeInTheDocument();
    expect(screen.getByRole("heading", { name: "Why it is built this way" })).toBeInTheDocument();
    for (const item of [...pipeline.overview.how, ...pipeline.overview.why]) {
      expect(screen.getByRole("heading", { name: item.title })).toBeInTheDocument();
    }
    await screen.findByText(String(content.stats.sectionCount));
    const cited = pipeline.overview.why.flatMap((item) => citations(item, new Map(), pipeline.nodes))[0];
    await user.click(screen.getAllByRole("link", { name: cited.label })[0]);
    expect(await screen.findByRole("dialog", { name: cited.label })).toBeInTheDocument();
  });

  it("opens a node's evidence from the chart and closes it again", async () => {
    const user = userEvent.setup();
    serveGenerated();
    render(<App />);
    await screen.findByText(String(content.stats.sectionCount));
    const node = pipeline.nodes[3];
    await user.click(screen.getByRole("button", { name: new RegExp(`^${node.title.replace(/[()]/g, ".")} — `) }));
    expect(screen.getByRole("dialog", { name: node.title })).toBeInTheDocument();
    expect(window.location.hash).toBe(`#/flow/${node.id}`);
    await user.keyboard("{Escape}");
    await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
    expect(window.location.hash).not.toContain(node.id);
  });

  it("opens the node a link names, and closes it without leaving the page", async () => {
    const node = pipeline.nodes[5];
    window.history.replaceState(null, "", `#/flow/${node.id}`);
    serveGenerated();
    render(<App />);
    expect(screen.getByRole("dialog", { name: node.title })).toBeInTheDocument();
    await userEvent.setup().click(screen.getByRole("button", { name: "Close" }));
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(window.location.hash).toBe("#/flow");
  });

  it("follows the back button between views", async () => {
    const user = userEvent.setup();
    serveGenerated();
    render(<App />);
    await screen.findByText(String(content.stats.sectionCount));
    await user.click(screen.getByRole("button", { name: "Payloads" }));
    expect(window.location.hash).toBe("#/payloads");
    act(() => window.history.back());
    await screen.findByRole("heading", { name: "The parse path" });
  });

  it("switches between the three views", async () => {
    const user = userEvent.setup();
    serveGenerated();
    render(<App />);
    await screen.findByText(String(content.stats.sectionCount));

    await user.click(screen.getByRole("button", { name: "Experiments" }));
    expect(screen.getByRole("heading", { name: "Experiments" })).toBeInTheDocument();
    expect(screen.getByRole("searchbox")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Payloads" }));
    expect(screen.getByRole("heading", { name: "By payload" })).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Parse path" }));
    expect(screen.getByRole("heading", { name: "The parse path" })).toBeInTheDocument();
  });

  it("toggles the colour scheme", async () => {
    const user = userEvent.setup();
    serveGenerated();
    render(<App />);
    await user.click(screen.getByRole("button", { name: "Toggle colour scheme" }));
    const theme = document.documentElement.dataset.theme;
    await user.click(screen.getByRole("button", { name: "Toggle colour scheme" }));
    expect(document.documentElement.dataset.theme).not.toBe(theme);
  });

  it("says how to regenerate when a bundle cannot load", async () => {
    serveGenerated((path) => path === "traces.json");
    render(<App />);
    expect(await screen.findByText(/Could not load the generated content: Error: traces.json: 500/)).toBeInTheDocument();
    expect(screen.getByText("./Web/generate")).toBeInTheDocument();
  });
});
