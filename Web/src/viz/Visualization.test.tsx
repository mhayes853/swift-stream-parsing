import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { pipeline, traces } from "../test/fixtures";
import type { VizKind } from "../types";
import { Visualization } from ".";

// Every animation, driven by the committed traces: it has to draw, step to its end and back, and
// report its trace as verified — a drifted mirror fails `./Web/generate traces`, so a warning here
// would mean the bundle and the site disagree.

const kinds = [...new Set(pipeline.nodes.map((n) => n.viz).filter((v): v is VizKind => !!v))];

describe("Visualization", () => {
  it("draws nothing until the traces arrive", () => {
    const { container } = render(<Visualization kind="stringRun" traces={null} />);
    expect(container).toBeEmptyDOMElement();
  });

  it.each(kinds)("%s steps from its first frame to its last", (kind) => {
    const { container } = render(<Visualization kind={kind} traces={traces} />);
    const slider = screen.getByRole("slider");
    const last = Number(slider.getAttribute("max"));
    expect(container.querySelector(".step-note")).not.toBeEmptyDOMElement();

    fireEvent.change(slider, { target: { value: String(last) } });
    expect(screen.getByText(`${last + 1} / ${last + 1}`)).toBeInTheDocument();
    expect(container.querySelector(".step-note")).not.toBeEmptyDOMElement();

    fireEvent.change(slider, { target: { value: "0" } });
    expect(screen.getByText(`1 / ${last + 1}`)).toBeInTheDocument();
    expect(container.textContent).not.toContain("⚠");
  });

  it("switches case and starts the new one from the beginning", () => {
    render(<Visualization kind="number" traces={traces} />);
    const slider = screen.getByRole("slider");
    fireEvent.change(slider, { target: { value: "2" } });
    const next = traces.number.cases.find((c, i) => i > 0 && c.steps.length > 0)!;
    fireEvent.click(screen.getByRole("button", { name: next.text }));
    expect(screen.getByRole("slider")).toHaveValue("0");
  });

  it("follows a hovered lane through the tables", () => {
    const { container } = render(<Visualization kind="utf8" traces={traces} />);
    const lane = container.querySelectorAll(".vec-stack .vec-lane")[5];
    fireEvent.mouseOver(lane);
    expect(screen.getByText(/^Lane/, { selector: ".viz-caption" })).toHaveTextContent("Lane 5");
  });
});
