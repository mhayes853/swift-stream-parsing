import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { sectionsByPath } from "../lib/evidence";
import { content, pipeline, serveGenerated, traces } from "../test/fixtures";
import type { PipelineNode } from "../types";
import { DetailPanel } from "./DetailPanel";

const sections = sectionsByPath(content.doc.sections);
const titleOf = (id: string) => pipeline.nodes.find((n) => n.id === id)?.title;

function open(node: PipelineNode, onClose = vi.fn()) {
  serveGenerated();
  render(<DetailPanel node={node} sections={sections} traces={traces} titleOf={titleOf} onClose={onClose} />);
  return onClose;
}

const tab = (name: string) => screen.getByRole("tab", { name: new RegExp(`^${name}`) });

/** The node with the most experiments, so the tabs have something in them. */
const busiest = [...pipeline.nodes].sort(
  (a, b) =>
    b.evidence.doc.filter((p) => sections.get(p)?.verdict !== "neutral").length -
    a.evidence.doc.filter((p) => sections.get(p)?.verdict !== "neutral").length
)[0];

describe("DetailPanel", () => {
  it("opens on the explanation, with the node's own chart", () => {
    open(busiest);
    expect(screen.getByRole("dialog", { name: busiest.title })).toBeInTheDocument();
    expect(tab("Explanation")).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("img", { name: `Control flow inside ${busiest.title}. Select a step to read what it does.` })).toBeInTheDocument();
  });

  it("counts what is under each tab", () => {
    open(busiest);
    const experiments = busiest.evidence.doc.filter((p) => sections.get(p)?.verdict !== "neutral").length;
    expect(tab("Experiments")).toHaveTextContent(`Experiments${experiments}`);
    expect(tab("Source")).toHaveTextContent(`Source${busiest.evidence.source.length}`);
  });

  it("lists the experiments rejections first", async () => {
    const user = userEvent.setup();
    open(busiest);
    await user.click(tab("Experiments"));
    const verdicts = [...document.querySelectorAll(".panel-body .verdict")].map((v) => v.textContent);
    const rank = { Rejected: 0, Mixed: 1, Landed: 2 } as Record<string, number>;
    expect(verdicts.map((v) => rank[v!])).toEqual([...verdicts.map((v) => rank[v!])].sort());
  });

  it("loads the source declarations when the Source tab opens", async () => {
    const user = userEvent.setup();
    open(busiest);
    await user.click(tab("Source"));
    const symbol = busiest.evidence.source[0].split(":")[1];
    const summaries = await screen.findAllByText(new RegExp(symbol), { selector: ".summary-symbol" });
    expect(summaries.length).toBeGreaterThan(0);
  });

  it("selects a step in its chart and describes it", async () => {
    const user = userEvent.setup();
    open(busiest);
    const step = busiest.steps[1];
    await user.click(screen.getByRole("button", { name: new RegExp(`^${step.title.replace(/[`()]/g, ".")}`) }));
    expect(document.querySelector(".algo-card h4")).toHaveTextContent(step.title.replace(/`/g, ""));
  });

  it("closes on Escape, on the close button and on the scrim", async () => {
    const user = userEvent.setup();
    const onClose = open(busiest);
    await user.keyboard("{Escape}");
    await user.click(screen.getByRole("button", { name: "Close" }));
    await user.click(document.querySelector(".scrim")!);
    expect(onClose).toHaveBeenCalledTimes(3);
  });

  it("writes out where the node goes next, for a screen that cannot hover", () => {
    // Shown only under `(hover: none)` by the stylesheet, which jsdom does not apply; what is tested
    // here is that the content is there and marked as the touch-only copy.
    const node = pipeline.nodes.find((n) => n.next.length > 1)!;
    open(node);
    const reaches = document.querySelector(".reaches")!;
    expect(reaches).toHaveClass("touch-only");
    expect(within(reaches as HTMLElement).getAllByRole("listitem")).toHaveLength(node.next.length);
    expect(reaches).toHaveTextContent(titleOf(node.next[0].to)!);
  });

  it("opens every node in the pipeline", () => {
    serveGenerated();
    for (const node of pipeline.nodes) {
      const { unmount } = render(
        <DetailPanel node={node} sections={sections} traces={traces} titleOf={titleOf} onClose={() => {}} />
      );
      expect(screen.getByRole("dialog", { name: node.title })).toBeInTheDocument();
      unmount();
    }
  });
});
