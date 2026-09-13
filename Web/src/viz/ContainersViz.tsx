import type { TapeMark } from "../lib/viz";
import type { ContainerTrace } from "../types";
import { InputTape, NestingRegister, StepBar, StepNote, useSteps } from "./common";

const OPEN = new Set(["beginObject", "beginArray"]);
const CLOSE = new Set(["endObject", "endArray"]);

/**
 * The nesting register, driven by a real parse.
 *
 * `depth` plus one `UInt64` is the whole of the parser's container state: bit *n* is 1 when the
 * container at depth *n* is an object and 0 when it is an array. The token stream here is the
 * parser's actual output; the bits are re-derived from it by the parser's own documented rule,
 * because the fields themselves are internal to the module.
 *
 * Each step marks the token's own bytes in the document. Those offsets are the parser's: they come
 * from the spans it hands the sink, cross-checked against a cursor that skips whitespace with the
 * shipped scanner. Without them the animation shows a register changing and leaves the reader to
 * guess which part of the input did it.
 */
export function ContainersViz({ trace }: { trace: ContainerTrace }) {
  const steps = trace.steps;
  const player = useSteps(steps.length, 900);
  const { index } = player;
  const step = steps[index];
  if (!step) return null;

  const bytes = Array.from(new TextEncoder().encode(trace.sample));
  const marks: TapeMark[] = [
    { from: 0, to: step.offset, kind: "done" },
    { from: step.offset, to: step.offset + step.length, kind: "cursor" }
  ];

  const changes = OPEN.has(step.event) || CLOSE.has(step.event);

  return (
    <div className="viz">
      <StepBar player={player} label="Token" />

      <StepNote op={step.event}>
        Bytes {step.offset}–{step.offset + step.length - 1} of the document
        {step.text ? (
          <>
            {" "}
            — <code>{JSON.stringify(step.text)}</code>
          </>
        ) : null}
        . {changes ? "The register changes." : "The register does not change."}
      </StepNote>

      <InputTape
        bytes={bytes}
        marks={marks}
        blockSize={0}
        label="the document"
        caption={
          <>
            Filled is the token this step is on; everything to its left has been parsed. Only{" "}
            {steps.filter((s) => OPEN.has(s.event) || CLOSE.has(s.event)).length} of these{" "}
            {steps.length} tokens touch the register below.
          </>
        }
      />

      <div style={{ display: "flex", alignItems: "center", gap: 12, margin: "12px 0 6px", flexWrap: "wrap" }}>
        <span
          className="chip active"
          style={{
            background: OPEN.has(step.event)
              ? "color-mix(in srgb, var(--series-1) 22%, var(--surface-1))"
              : CLOSE.has(step.event)
                ? "color-mix(in srgb, var(--series-2) 22%, var(--surface-1))"
                : "var(--surface-1)"
          }}
        >
          {step.event}
          {step.text ? ` ${JSON.stringify(step.text)}` : ""}
        </span>
        <span style={{ fontSize: 13, color: "var(--text-secondary)" }}>
          token {index + 1} of {steps.length} · depth{" "}
          <strong style={{ color: "var(--text-primary)" }}>{step.depthAfter}</strong>
        </span>
      </div>

      {/* The register. One cell per bit, low bit (depth 1) on the left. */}
      <NestingRegister
        bits={16}
        depthBefore={step.depthBefore}
        depthAfter={step.depthAfter}
        isObject={(bit) => step.containersBits[bit] === 1}
        ringed={step.depthAfter - 1}
        epoch={index}
      >
        <span style={{ alignSelf: "center", marginLeft: 8, fontSize: 12, color: "var(--text-muted)" }}>
          … {trace.maximumDepth - 16} more bits
        </span>
      </NestingRegister>

      <div className="legend">
        <span>
          <i style={{ background: "var(--series-1)" }} />1 = object <code>{"{"}</code>
        </span>
        <span>
          <i style={{ background: "var(--series-2)" }} />0 = array <code>[</code>
        </span>
        <span>
          <i style={{ background: "var(--axis)" }} />above depth, unused
        </span>
      </div>

      <p className="viz-caption">
        {OPEN.has(step.event) ? (
          <>
            A container opens: a {step.event === "beginObject" ? "1" : "0"} is shifted in at bit{" "}
            {step.depthBefore + 1} and depth becomes {step.depthAfter}. No allocation, no stack — the
            entire nesting state is two registers.
          </>
        ) : CLOSE.has(step.event) ? (
          <>
            A container closes. Depth drops to {step.depthAfter}; the bit above it is simply no longer
            read, so there is nothing to clear — the pulse marks the bit that stopped counting, not a
            bit that was written.
          </>
        ) : (
          <>
            A value token. It does not touch the nesting register at all — which is the point: the
            state that changes per byte stays in registers, and everything else stays out of the way.
          </>
        )}
      </p>

      <p className="viz-note">
        The ceiling is <strong>{trace.maximumDepth}</strong> levels, measured by asking the shipped
        parser where it refuses rather than by copying the constant. Depth beyond it is rejected
        rather than spilled, which is exactly what keeps container tracking to a single register.
        {!trace.offsetsVerified && (
          <strong style={{ color: "var(--warning)" }}>
            {" "}
            ⚠ The token offsets above did not agree with the parser's own spans.
          </strong>
        )}
      </p>
    </div>
  );
}
