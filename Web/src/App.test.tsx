import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { App } from "./App";
import { content, pipeline, serveGenerated } from "./test/fixtures";

describe("App", () => {
  it("loads the bundles and draws the parse path with the log's numbers", async () => {
    serveGenerated();
    render(<App />);
    expect(screen.getByRole("heading", { name: "The parse path" })).toBeInTheDocument();
    expect(await screen.findByText(String(content.stats.sectionCount))).toBeInTheDocument();
    expect(screen.getByText(String(pipeline.nodes.length))).toBeInTheDocument();
  });

  it("opens a node's evidence from the chart and closes it again", async () => {
    const user = userEvent.setup();
    serveGenerated();
    render(<App />);
    await screen.findByText(String(content.stats.sectionCount));
    const node = pipeline.nodes[3];
    await user.click(screen.getByRole("button", { name: new RegExp(`^${node.title.replace(/[()]/g, ".")} — `) }));
    expect(screen.getByRole("dialog", { name: node.title })).toBeInTheDocument();
    await user.keyboard("{Escape}");
    expect(screen.queryByRole("dialog")).toBeNull();
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
