import { act, fireEvent, render, screen } from "@testing-library/react";
import { useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { media } from "../test/setup";
import { Choices, InputTape, StepBar, useSteps } from "./common";

/** A player over `count` steps, with a second case to switch to. */
function Player({ count = 3, interval = 100 }: { count?: number; interval?: number }) {
  const [which, setWhich] = useState(0);
  const player = useSteps(count, interval, which);
  return (
    <>
      <Choices
        items={["first", "second"]}
        selected={which}
        onSelect={setWhich}
        itemKey={(name) => name}
        label={(name) => name}
      />
      <StepBar player={player} label="Step" />
      <output>{player.index}</output>
    </>
  );
}

const shown = () => screen.getByRole("status").textContent;

describe("useSteps and StepBar", () => {
  it("plays through every step and stops on the last one", () => {
    vi.useFakeTimers();
    render(<Player count={3} />);
    fireEvent.click(screen.getByRole("button", { name: "Play" }));
    expect(screen.getByRole("button", { name: "Pause" })).toBeInTheDocument();
    act(() => vi.advanceTimersByTime(100));
    expect(shown()).toBe("1");
    act(() => vi.advanceTimersByTime(100));
    expect(shown()).toBe("2");
    act(() => vi.advanceTimersByTime(1000));
    expect(shown()).toBe("2");
    expect(screen.getByRole("button", { name: "Play" })).toBeInTheDocument();
  });

  it("starts over when played again from the end", () => {
    vi.useFakeTimers();
    render(<Player count={2} />);
    fireEvent.change(screen.getByRole("slider", { name: "Step" }), { target: { value: "1" } });
    fireEvent.click(screen.getByRole("button", { name: "Play" }));
    expect(shown()).toBe("0");
  });

  it("seeks with the scrubber and says where it is", () => {
    render(<Player count={5} />);
    fireEvent.change(screen.getByRole("slider", { name: "Step" }), { target: { value: "3" } });
    expect(shown()).toBe("3");
    expect(screen.getByText("4 / 5")).toBeInTheDocument();
  });

  it("rewinds when the case changes", () => {
    render(<Player count={5} />);
    fireEvent.change(screen.getByRole("slider", { name: "Step" }), { target: { value: "3" } });
    fireEvent.click(screen.getByRole("button", { name: "second" }));
    expect(shown()).toBe("0");
    expect(screen.getByRole("button", { name: "second" })).toHaveAttribute("aria-pressed", "true");
  });

  it("steps once per press instead of autoplaying under reduced motion", () => {
    vi.useFakeTimers();
    media.add("(prefers-reduced-motion: reduce)");
    render(<Player count={3} />);
    fireEvent.click(screen.getByRole("button", { name: "Play" }));
    expect(shown()).toBe("1");
    act(() => vi.advanceTimersByTime(1000));
    expect(shown()).toBe("1");
    expect(screen.getByRole("button", { name: "Play" })).toBeInTheDocument();
  });
});

describe("InputTape", () => {
  it("marks each byte with the last mark covering it, and rules every block", () => {
    const { container } = render(
      <InputTape
        bytes={Array.from({ length: 20 }, (_, i) => 0x61 + i)}
        marks={[
          { from: 0, to: 16, kind: "window" },
          { from: 2, to: 3, kind: "cursor" }
        ]}
        label="sample"
      />
    );
    const bytes = container.querySelectorAll(".tape-byte");
    expect(bytes).toHaveLength(20);
    expect(bytes[1]).toHaveClass("window");
    expect(bytes[2]).toHaveClass("cursor");
    expect(bytes[16]).toHaveClass("tick");
    expect(bytes[17]).not.toHaveClass("window");
    expect(screen.getByText("20 bytes")).toBeInTheDocument();
  });
});
