import { useState } from "react";
import type { NumberCase } from "../types";
import { glyph, StepBar, useSteps, VerifiedNote } from "./common";

/**
 * `streamShortInteger` — eight bytes, backwards.
 *
 * The word is shown in memory order (little-endian storage, which is the order the digits sit in),
 * so the mask visibly clears the junk *below* the token and the bias only ever touches kept lanes.
 */
export function NumberViz({ cases }: { cases: NumberCase[] }) {
  const [which, setWhich] = useState(0);
  const active = cases[which];
  const steps = active?.steps ?? [];
  const { index, setIndex, playing, play } = useSteps(steps.length, 1300);

  if (!active) return null;
  const step = steps[index];

  return (
    <div className="viz">
      <div className="chip-row">
        {cases.map((c, i) => (
          <button
            key={c.text}
            className={`chip ${i === which ? "active" : ""}`}
            onClick={() => {
              setWhich(i);
              setIndex(0);
            }}
          >
            {c.text}
          </button>
        ))}
      </div>

      {steps.length === 0 ? (
        <p className="viz-caption">
          <code>{active.text}</code> is {active.digitCount} digit
          {active.digitCount === 1 ? "" : "s"} of scanned token, and this kernel takes only unsigned
          integers of one to eight digits. It goes to the structured walk instead — the digit test
          <em> is</em> the shape test, so rejecting it costs nothing beyond the test itself. A
          nine-to-sixteen digit kernel and a decimal kernel were both built and measured for these
          shapes, and both were rejected.
        </p>
      ) : (
        <>
          <StepBar
            index={index}
            count={steps.length}
            playing={playing}
            onPlay={play}
            onSeek={setIndex}
            label="Kernel stage"
          />

          <div style={{ fontFamily: "var(--font-mono)", fontSize: 12, color: "var(--text-muted)", marginBottom: 4 }}>
            input <span style={{ color: "var(--text-secondary)" }}>{active.prefix.replace(/\n/g, "\\n").replace(/\t/g, "\\t") + active.text}</span> — the kernel loads the eight bytes
            <em> ending</em> at the token
          </div>

          <div className="lanes">
            {step.bytes.map((byte, i) => {
              // The token occupies the highest-addressed `digitCount` bytes of the word.
              const inToken = i >= 8 - active.digitCount;
              return (
                <div
                  key={i}
                  className={`lane ${inToken ? "q" : "dim"}`}
                  style={{ width: 46 }}
                  title={`byte ${i}`}
                >
                  <span className="glyph" style={{ fontSize: 11 }}>
                    {byte.toString(16).padStart(2, "0")}
                  </span>
                  <span className="idx">{glyph(byte)}</span>
                </div>
              );
            })}
          </div>

          <div style={{ display: "flex", gap: 10, alignItems: "baseline", marginTop: 4 }}>
            <strong style={{ fontFamily: "var(--font-mono)", fontSize: 14 }}>{step.label}</strong>
            <span style={{ fontFamily: "var(--font-mono)", fontSize: 12, color: "var(--text-muted)" }}>
              0x{step.hex}
            </span>
          </div>

          <p className="viz-caption">{step.detail}</p>

          <p className="viz-note">
            Blue lanes are the token; dimmed lanes are the junk behind the cursor that the mask
            removes.{" "}
            {active.acceptedByShortInteger ? (
              <>
                Accepted, value <strong>{active.value}</strong> — no loop, no data-dependent branch.
              </>
            ) : (
              <>Rejected by the digit test, which is also the shape test.</>
            )}
          </p>
          <VerifiedNote verified={active.verified} />
        </>
      )}
    </div>
  );
}
