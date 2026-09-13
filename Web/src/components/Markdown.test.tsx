import { render, screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { Markdown, VerdictChip } from "./Markdown";

describe("Markdown", () => {
  it("draws inline markup as elements, not as punctuation", () => {
    render(<Markdown>{"A `kernel` is **fast** and *small*, see [the log](http://example.com)."}</Markdown>);
    expect(screen.getByText("kernel").tagName).toBe("CODE");
    expect(screen.getByText("fast").tagName).toBe("STRONG");
    expect(screen.getByText("small").tagName).toBe("EM");
    expect(screen.getByRole("link", { name: "the log" })).toHaveAttribute("href", "http://example.com");
    expect(document.body.textContent).not.toContain("*");
  });

  it("draws a measurement table with its numbers aligned and its deltas signed", () => {
    render(<Markdown>{"| payload | Δ |\n|---|--:|\n| twitter | +4.7% |\n| canada | −2.1% |"}</Markdown>);
    const table = screen.getByRole("table");
    expect(within(table).getAllByRole("columnheader").map((th) => th.textContent)).toEqual(["payload", "Δ"]);
    expect(within(table).getByText("+4.7%")).toHaveClass("num", "delta", "pos");
    expect(within(table).getByText("−2.1%")).toHaveClass("delta", "neg");
    // It scrolls in its own box rather than widening the page.
    expect(table.parentElement).toHaveClass("table-scroll");
  });

  it("highlights a fenced block in its language", () => {
    const { container } = render(<Markdown>{"```swift\nlet a = 1\n```"}</Markdown>);
    expect(container.querySelector("code.hl-swift .t-kw")).toHaveTextContent("let");
  });

  it("draws lists and quotes", () => {
    render(<Markdown>{"- one\n- two\n\n> said"}</Markdown>);
    expect(screen.getAllByRole("listitem").map((li) => li.textContent)).toEqual(["one", "two"]);
    expect(screen.getByText("said").tagName).toBe("BLOCKQUOTE");
  });
});

describe("VerdictChip", () => {
  it("writes the verdict out, so it never rests on colour", () => {
    render(<VerdictChip verdict="rejected" />);
    expect(screen.getByText("Rejected")).toHaveClass("verdict", "rejected");
  });
});
