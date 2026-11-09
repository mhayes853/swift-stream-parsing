import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { sectionsByPath } from "../lib/evidence";
import { content, pipeline } from "../test/fixtures";
import { media } from "../test/setup";
import { FlowChart } from "./FlowChart";

const sections = sectionsByPath(content.doc.sections);
const nodeButton = (title: string) => screen.getByRole("button", { name: new RegExp(`^${title.replace(/[()]/g, ".")} — `) });

describe("FlowChart", () => {
  it("draws a button for every node and a row for every stage", () => {
    render(<FlowChart pipeline={pipeline} sections={sections} selected={null} onSelect={() => {}} />);
    for (const node of pipeline.nodes) expect(nodeButton(node.title)).toBeInTheDocument();
    for (const stage of pipeline.stages) {
      expect(document.querySelector(".flow")!.textContent).toContain(stage.title.split(" ")[0]);
    }
  });

  it("selects a node by click or keyboard", async () => {
    const user = userEvent.setup();
    const onSelect = vi.fn();
    render(<FlowChart pipeline={pipeline} sections={sections} selected={null} onSelect={onSelect} />);
    const node = pipeline.nodes[1];
    await user.click(nodeButton(node.title));
    nodeButton(node.title).focus();
    await user.keyboard("{Enter}");
    expect(onSelect).toHaveBeenCalledTimes(2);
    expect(onSelect).toHaveBeenLastCalledWith(node);
  });

  it("opens the call card on hover, where there is hover", () => {
    media.add("(hover: hover)");
    render(<FlowChart pipeline={pipeline} sections={sections} selected={null} onSelect={() => {}} />);
    const node = pipeline.nodes.find((n) => n.next.length > 1)!;
    fireEvent.mouseEnter(nodeButton(node.title));
    const card = document.querySelector(".flow-card")!;
    expect(card).toHaveTextContent(node.title);
    expect(card.querySelectorAll("li")).toHaveLength(node.next.length);
    fireEvent.mouseLeave(nodeButton(node.title));
    expect(document.querySelector(".flow-card")).toBeNull();
  });

  it("draws no card, and reserves no rail for one, on a touch screen", () => {
    const { container } = render(<FlowChart pipeline={pipeline} sections={sections} selected={null} onSelect={() => {}} />);
    const node = pipeline.nodes.find((n) => n.next.length > 1)!;
    fireEvent.mouseEnter(nodeButton(node.title));
    expect(document.querySelector(".flow-card")).toBeNull();

    media.add("(hover: hover)");
    const touchWidth = Number(container.querySelector("svg.flow")!.getAttribute("width"));
    const { container: withHover } = render(
      <FlowChart pipeline={pipeline} sections={sections} selected={null} onSelect={() => {}} />
    );
    expect(Number(withHover.querySelector("svg.flow")!.getAttribute("width"))).toBeGreaterThan(touchWidth);
  });

  it("labels every arrow", () => {
    const { container } = render(<FlowChart pipeline={pipeline} sections={sections} selected={null} onSelect={() => {}} />);
    const arrows = pipeline.nodes.reduce((n, node) => n + node.next.length, 0);
    expect(container.querySelectorAll(".flow-edge-label")).toHaveLength(arrows);
  });
});
