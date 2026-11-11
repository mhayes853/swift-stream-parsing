import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";
import { section } from "../test/fixtures";
import type { Measurement } from "../types";
import { Payloads } from "./Payloads";

const m = (payload: string, value: number): Measurement => ({ payload, rowLabel: "bulk", column: "", value, isDelta: true });
const sections = [
  section({ title: "Landed: tokens", measurements: [m("twitter", 11.8), m("canada", -2.5)] }),
  section({ title: "Rejected: peel", measurements: [m("twitter", -3.3)] })
];

describe("Payloads", () => {
  it("opens on the most-measured payload, gains first", () => {
    render(<Payloads sections={sections} />);
    expect(screen.getByRole("button", { name: /twitter\.json/ })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getAllByRole("row").slice(1).map((r) => r.lastElementChild!.textContent)).toEqual(["▲ +11.8%", "▼ -3.3%"]);
  });

  it("switches payload", async () => {
    const user = userEvent.setup();
    render(<Payloads sections={sections} />);
    await user.click(screen.getByRole("button", { name: /canada\.json/ }));
    expect(screen.getAllByRole("row")).toHaveLength(2);
    expect(screen.getByText("Landed: tokens")).toBeInTheDocument();
  });

  it("picks a payload once the content arrives, rather than the default it mounted with", () => {
    const { rerender } = render(<Payloads sections={[]} />);
    expect(screen.getByText("No signed deltas recorded for this payload.")).toBeInTheDocument();
    rerender(<Payloads sections={sections} />);
    expect(screen.getByRole("button", { name: /twitter\.json/ })).toHaveAttribute("aria-pressed", "true");
  });
});
