import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { library, macrosContent, pipeline, serveGenerated, testsContent, traces } from "../test/fixtures";
import { MacrosView } from "./MacrosView";
import { TestsView } from "./TestsView";

const titleOf = (id: string) => pipeline.nodes.find((n) => n.id === id)?.title;

describe("TestsView", () => {
  it("counts the whole test index and lists every guarantee", () => {
    render(
      <TestsView content={testsContent} library={library} error={null} traces={traces} titleOf={titleOf} onNode={() => {}} />
    );
    expect(screen.getByText(String(library.tests.cases.length))).toBeInTheDocument();
    for (const g of testsContent.guarantees) {
      expect(screen.getByRole("heading", { name: g.title, level: 3 })).toBeInTheDocument();
    }
  });

  it("draws the chunk cut grid from the recorded trace", () => {
    render(
      <TestsView content={testsContent} library={library} error={null} traces={traces} titleOf={titleOf} onNode={() => {}} />
    );
    const grid = screen.getByRole("table", { name: /which call delivered each token/i });
    expect(within(grid).getAllByRole("row")).toHaveLength(traces.chunkCuts.tokens.length + 1);
  });

  it("opens a parse path node from a guarantee", async () => {
    const user = userEvent.setup();
    const onNode = vi.fn();
    render(
      <TestsView content={testsContent} library={library} error={null} traces={traces} titleOf={titleOf} onNode={onNode} />
    );
    const first = testsContent.guarantees[0];
    await user.click(screen.getAllByRole("button", { name: `${titleOf(first.node[0])} →` })[0]);
    expect(onNode).toHaveBeenCalledWith(first.node[0]);
  });

  it("says so while the index loads, and when it fails", () => {
    const { rerender } = render(
      <TestsView content={testsContent} library={null} error={null} traces={null} titleOf={titleOf} onNode={() => {}} />
    );
    expect(screen.getByText(/Loading the test index/)).toBeInTheDocument();
    rerender(
      <TestsView content={testsContent} library={null} error="404" traces={null} titleOf={titleOf} onNode={() => {}} />
    );
    expect(screen.getByText(/Could not load the test index: 404/)).toBeInTheDocument();
  });
});

describe("MacrosView", () => {
  it("labels every block of the first example's expansion with its region", () => {
    serveGenerated();
    render(<MacrosView content={macrosContent} library={library} error={null} titleOf={titleOf} onNode={() => {}} />);
    const regions = new Set(macrosContent.regions.map((r) => r.title));
    const tags = document.querySelectorAll(".expansion-tag");
    expect(tags.length).toBeGreaterThan(5);
    for (const tag of tags) expect(regions).toContain(tag.textContent);
  });

  it("picks out a region and names what reads it", async () => {
    serveGenerated();
    const user = userEvent.setup();
    const onNode = vi.fn();
    render(<MacrosView content={macrosContent} library={library} error={null} titleOf={titleOf} onNode={onNode} />);
    const legend = screen.getByRole("group", { name: "Generated regions" });
    await user.click(within(legend).getByRole("button", { name: /^key match/ }));
    expect(document.querySelectorAll(".expansion-block.lit").length).toBeGreaterThan(0);
    expect(document.querySelectorAll(".expansion-block.dim").length).toBeGreaterThan(0);
    await user.click(screen.getByRole("button", { name: titleOf("keys") }));
    expect(onNode).toHaveBeenCalledWith("keys");
  });

  it("decodes the matcher's words into the keys of the selected example", async () => {
    serveGenerated();
    const user = userEvent.setup();
    render(<MacrosView content={macrosContent} library={library} error={null} titleOf={titleOf} onNode={() => {}} />);
    await user.click(screen.getByRole("button", { name: "Keys and aliases" }));
    const words = document.querySelector(".word-matches") as HTMLElement;
    expect(within(words).getByText('"customKeyName"')).toBeInTheDocument();
    expect(within(words).getByText('"name2"')).toBeInTheDocument();
  });

  it("draws the generation chart from macros.json", () => {
    serveGenerated();
    render(<MacrosView content={macrosContent} library={library} error={null} titleOf={titleOf} onNode={() => {}} />);
    expect(screen.getByRole("heading", { name: macrosContent.chart.title })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: new RegExp(`Control flow inside ${macrosContent.chart.title}`) })).toBeInTheDocument();
  });
});
