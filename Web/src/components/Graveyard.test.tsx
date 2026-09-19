import { render, screen, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { history, section } from "../test/fixtures";
import { Graveyard } from "./Graveyard";

const sections = [
  section({
    title: "Rejected: a movemask for the number scanner",
    verdict: "rejected",
    summary: "Slower on canada.",
    history: history("2026-08-20T10:00:00-07:00")
  }),
  section({
    title: "Rejected: a wider peel",
    verdict: "rejected",
    summary: "It cost citm.",
    markdown: "The peel read four bytes. Nothing about the movemask here.",
    history: history("2026-08-25T10:00:00-07:00")
  }),
  section({
    title: "Landed: whole tokens in the run",
    verdict: "landed",
    summary: "Twitter gains.",
    markdown: "Values finish in the run, and the movemask moved out of the loop.",
    history: history("2026-08-29T10:00:00-07:00")
  }),
  section({ title: "How the run works", summary: "Context only." })
];

const titles = () =>
  [...document.querySelectorAll(".evidence-item summary .summary-head > span:first-child")].map((s) => s.textContent);

describe("Graveyard", () => {
  it("opens on the rejections, newest first, and leaves out the sections with no verdict", () => {
    render(<Graveyard sections={sections} />);
    expect(titles()).toEqual(["Rejected: a wider peel", "Rejected: a movemask for the number scanner"]);
    expect(screen.getByText(/2 rejected, 1 landed, 0 mixed/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Rejected/ })).toHaveAttribute("aria-pressed", "true");
  });

  it("switches verdict and reverses the order", async () => {
    const user = userEvent.setup();
    render(<Graveyard sections={sections} />);
    await user.click(screen.getByRole("button", { name: /Everything with a verdict/ }));
    expect(titles()).toHaveLength(3);
    await user.click(screen.getByRole("button", { name: "Newest first" }));
    expect(titles()[0]).toBe("Rejected: a movemask for the number scanner");
  });

  it("searches the whole write-up and shows what matched", async () => {
    const user = userEvent.setup();
    render(<Graveyard sections={sections} />);
    await user.type(screen.getByRole("searchbox", { name: "Search every experiment" }), "four bytes");

    expect(titles()).toEqual(["Rejected: a wider peel"]);
    expect(screen.getByText("1 of 3 experiment matches.")).toBeInTheDocument();
    const snippet = document.querySelector(".snippet")!;
    expect(snippet).toHaveTextContent("1 hit in the write-up");
    expect(within(snippet as HTMLElement).getByText("four").tagName).toBe("MARK");
  });

  it("marks a title hit in the title itself", async () => {
    const user = userEvent.setup();
    render(<Graveyard sections={sections} />);
    await user.type(screen.getByRole("searchbox"), "PEEL");
    expect(screen.getByText("peel", { selector: "mark" })).toBeInTheDocument();
  });

  it("offers the matches the verdict filter is hiding", async () => {
    const user = userEvent.setup();
    render(<Graveyard sections={sections} />);
    await user.type(screen.getByRole("searchbox"), "movemask");
    expect(titles()).toHaveLength(2);
    await user.click(screen.getByRole("button", { name: /1 more is behind the verdict filter/ }));
    expect(titles()).toHaveLength(3);
    expect(screen.getByRole("button", { name: /Everything with a verdict/ })).toHaveAttribute("aria-pressed", "true");
  });

  it("clears with the button or with Escape", async () => {
    const user = userEvent.setup();
    render(<Graveyard sections={sections} />);
    const field = screen.getByRole("searchbox");
    await user.type(field, "zzz");
    expect(screen.getByText("No experiment matches.")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Clear the search" }));
    expect(field).toHaveValue("");
    expect(field).toHaveFocus();

    await user.type(field, "zzz{Escape}");
    expect(field).toHaveValue("");
    expect(titles()).toHaveLength(2);
  });

  it("puts a day rule between experiments recorded on different days", () => {
    render(<Graveyard sections={sections} />);
    expect(screen.getAllByRole("heading", { level: 3 }).map((h) => h.textContent)).toEqual([
      "25 Aug 2026",
      "20 Aug 2026"
    ]);
  });
});
