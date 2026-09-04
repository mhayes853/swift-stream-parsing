import { useState } from "react";
import type { NumberCase } from "../types";
import type { Cell, TapeMark } from "./common";
import {
  diff,
  glyph,
  hex,
  InputTape,
  StepBar,
  StepNote,
  useSteps,
  VerifiedNote,
  VectorRow
} from "./common";

/**
 * `streamShortInteger` — eight bytes, backwards.
 *
 * The word is shown in memory order (little-endian storage, which is the order the digits sit in),
 * so the mask visibly clears the junk *below* the token and the bias only ever touches kept lanes.
 *
 * This kernel is the one place where the *same* register is rewritten by every step rather than a
 * new one being produced, so the animation marks the lanes each stage changed. That is the whole
 * reading of it: the mask changes only the junk, the bias changes only the digits, and the two
 * multiply-adds collapse eight lanes to four to two to one.
 */
export function NumberViz({ cases }: { cases: NumberCase[] }) {
  const [which, setWhich] = useState(0);
  const active = cases[which];
  const steps = active?.steps ?? [];
  const { index, setIndex, playing, play } = useSteps(steps.length, 1300);

  if (!active) return null;
  const step = steps[index];

  // The input as the kernel sees it: the hostile prefix the tests pad with, then the token. The
  // load is the eight bytes *ending* at the token, so it reaches back into the prefix.
  const text = active.prefix + active.text;
  const bytes = Array.from(new TextEncoder().encode(text));
  const tokenStart = active.prefix.length;
  const tokenEnd = tokenStart + active.text.length;
  const loadStart = Math.max(0, tokenEnd - 8);

  const marks: TapeMark[] = [
    { from: 0, to: loadStart, kind: "done" },
    { from: loadStart, to: tokenEnd, kind: "window" },
    { from: tokenStart, to: tokenEnd, kind: "cursor" }
  ];

  const tape = (
    <InputTape
      bytes={bytes}
      marks={marks}
      blockSize={0}
      label={`streamShortInteger — ${active.text}`}
      caption={
        <>
          Filled is the token; the paler bytes with it are the rest of the eight-byte load. The
          kernel reads <em>backwards</em> from the token's end, so it deliberately picks up{" "}
          {tokenStart - loadStart} byte{tokenStart - loadStart === 1 ? "" : "s"} of whatever
          preceded it — here the junk the tests pad with, because the mask-before-bias defect only
          shows up against bytes below <code>'0'</code>.
        </>
      }
    />
  );

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
        <>
          {tape}
          <p className="viz-caption">
            <code>{active.text}</code> is {active.digitCount} digit
            {active.digitCount === 1 ? "" : "s"} of scanned token, and this kernel takes only
            unsigned integers of one to eight digits. It goes to the structured walk instead — the
            digit test <em>is</em> the shape test, so rejecting it costs nothing beyond the test
            itself. A nine-to-sixteen digit kernel and a decimal kernel were both built and measured
            for these shapes, and both were rejected.
          </p>
        </>
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

          <StepNote op={step.label}>{step.detail}</StepNote>

          {tape}

          <div className="vec-stack">
            <VectorRow
              op={step.label}
              note={`0x${step.hex}`}
              epoch={index}
              phase="past"
              cells={wordCells(step.bytes, steps[index - 1]?.bytes, active.digitCount)}
            />
          </div>

          <p className="viz-caption">
            Pulsed lanes are the bytes this stage changed.{" "}
            {index === 0
              ? "The load itself: eight bytes in memory order, junk and all."
              : "Everything else in the register is exactly as the previous stage left it — one instruction, eight lanes."}
          </p>

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

/** One SWAR lane per byte of the word, with the token's lanes lit and the changed ones pulsed. */
function wordCells(now: number[], before: number[] | undefined, digitCount: number): Cell[] {
  const changed = diff(now, before);
  return now.map((byte, i) => ({
    // The token occupies the highest-addressed `digitCount` bytes of the word.
    text: hex(byte),
    sub: glyph(byte),
    on: i >= 8 - digitCount,
    dim: i < 8 - digitCount,
    changed: changed[i],
    title: `byte ${i} of the word`
  }));
}
