import type { SkipRunTrace } from "../types";
import type { TapeMark } from "./common";
import { InputTape, StepBar, StepNote, glyph, useSteps } from "./common";

const ACTION: Record<string, { word: string; note: string }> = {
  open: { word: "a bracket opens", note: "Depth up one, and a bit shifted into the register." },
  close: { word: "a bracket closes", note: "Depth down one. Not the one being waited for." },
  string: {
    word: "a string",
    note: "The same kernel the streaming path uses, minus every emission. An escape selector is consumed blind."
  },
  separator: { word: "a comma or colon", note: "Stepped over. Placement is not validated here." },
  number: {
    word: "a number",
    note: "The whole byte class in one scan. The grammar walk over it is what the skip omits."
  },
  literal: { word: "a literal byte", note: "One byte at a time; the words are not checked." },
  done: { word: "the matching close", note: "Depth is back where the skip began. This is the one call the sink gets." }
};

/**
 * The skip scanner, walking one subtree.
 *
 * `consumeSkipRun`'s intermediates cannot be seen from outside it, so the walk drawn here is
 * mirrored with the same `package` scanners the shipped loop calls, in the same order — and then
 * the shipped function is run over the same bytes from the same state. The two have to land on
 * the same cursor or `./Web/generate traces` fails, which is the same footing every kernel mirror
 * on this site stands on.
 */
export function SkipRunViz({ trace }: { trace: SkipRunTrace }) {
  const steps = trace.steps;
  const { index, setIndex, playing, play } = useSteps(steps.length, 850);
  const step = steps[index];
  if (!step) return null;

  const marks: TapeMark[] = [
    { from: 0, to: trace.from, kind: "done" },
    { from: step.offset, to: step.next, kind: "window" },
    { from: step.offset, to: step.offset + 1, kind: "cursor" },
    { from: step.next, to: step.next + 1, kind: "next" }
  ];

  const action = ACTION[step.action] ?? ACTION.literal;
  const consumed = step.next - step.offset;

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={steps.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Skip step"
      />

      <StepNote op={step.scanner ?? "switch byte"}>
        <code>{glyph(step.byte)}</code> at {step.offset}: {action.word}. {action.note}
        {consumed > 1 && ` ${consumed} bytes consumed in one step.`}
      </StepNote>

      <InputTape
        bytes={trace.bytes}
        marks={marks}
        blockSize={0}
        label="the subtree being skipped"
        caption={
          <>
            The cursor is the byte the <code>switch</code> is on; the shaded run is what this step
            consumes. The skip started at byte {trace.from} and ends at {trace.end}, which is where{" "}
            <code>consumeSkipRun</code> itself left the cursor.
          </>
        }
      />

      {/* The two registers the skip keeps. Same pair as the structural run, which is why a `[`
          closed by a `}` is still rejected inside a subtree nobody is delivering. */}
      <div className="skip-regs">
        <div>
          <span className="skip-reg-label">depth</span>
          <div className="lanes" style={{ gap: 3, margin: "6px 0 0" }}>
            {Array.from({ length: 6 }, (_, bit) => {
              const live = bit < step.depthAfter;
              const isObject = step.containers[bit] === "1";
              const moved = step.depthBefore !== step.depthAfter
                && bit === Math.min(step.depthBefore, step.depthAfter);
              return (
                <div
                  key={`${index}-${bit}`}
                  className={`lane ${live ? (isObject ? "q" : "b") : "dim"} ${
                    bit === trace.startDepth - 1 ? "terminator" : ""
                  } ${moved ? "chg" : ""}`}
                  style={{ width: 26 }}
                  title={
                    live
                      ? `depth ${bit + 1}: ${isObject ? "object" : "array"}`
                      : `depth ${bit + 1}: unused`
                  }
                >
                  <span className="glyph">{live ? (isObject ? "1" : "0") : "·"}</span>
                  <span className="idx">{bit + 1}</span>
                </div>
              );
            })}
          </div>
        </div>
        <div className="skip-target">
          <span className="skip-reg-label">skipEndDepth</span>
          <strong>{trace.startDepth - 1}</strong>
          <p>
            The close to stop at. Every other bracket moves the register and nothing else; the one
            that brings depth back to this is the only one that emits.
          </p>
        </div>
      </div>

      <p className="viz-caption">
        {step.emits ? (
          <>
            The matching close. <code>endObject</code>/<code>endArray</code> is delivered here and
            the run returns — the sink that answered <code>.skip</code> still sees its container
            close, so a frame pushed at the open is popped.
          </>
        ) : (
          <>
            Nothing is delivered. The interior is validated structurally — brackets match by kind,
            strings terminate, control bytes are still rejected and UTF-8 is still checked — but
            number grammar, escape selectors and separator placement are not, and a malformed
            interior a streaming sink would have rejected can pass here.
          </>
        )}
      </p>

      <p className="viz-note">
        {steps.length} steps over {trace.end - trace.from} bytes.
        {trace.verified ? (
          <>
            {" "}
            The mirrored walk and <code>consumeSkipRun</code> both ended at byte {trace.end}, and
            the shipped run delivered exactly one close.
          </>
        ) : (
          <strong style={{ color: "var(--warning)" }}>
            {" "}
            ⚠ The mirror ended at {trace.end} and the shipped scanner at {trace.shippedEnd}.
          </strong>
        )}
      </p>
    </div>
  );
}
