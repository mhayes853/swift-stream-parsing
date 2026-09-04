import type { WhitespaceTrace } from "../types";
import { glyph, Legend, StepBar, useSteps } from "./common";

/**
 * `streamWhitespaceEnd` at each of the call sites the parser makes it.
 *
 * The point of this one is the *branch*, not the scan: a single compare against 0x20 settles the
 * no-whitespace case, and the vector body lives behind a call so its register pressure never
 * reaches the parse loop.
 */
export function WhitespaceViz({ trace }: { trace: WhitespaceTrace }) {
  const calls = trace.calls;
  const { index, setIndex, playing, play } = useSteps(calls.length, 1200);
  const call = calls[index];
  if (!call) return null;

  const early = calls.filter((c) => c.earlyOut).length;

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={calls.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Scan call site"
      />

      <div style={{ fontSize: 12, color: "var(--text-muted)", fontFamily: "var(--font-mono)" }}>
        call at byte {call.from} · first byte 0x{call.firstByte.toString(16).padStart(2, "0")} (
        {glyph(call.firstByte)})
      </div>

      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 10,
          margin: "14px 0 4px",
          fontFamily: "var(--font-mono)",
          fontSize: 13
        }}
      >
        <span
          style={{
            padding: "4px 10px",
            borderRadius: 6,
            border: "1px solid var(--grid)",
            background: call.earlyOut ? "color-mix(in srgb, var(--good) 22%, var(--surface-1))" : "var(--surface-1)"
          }}
        >
          byte &gt; 0x20 ?
        </span>
        <span style={{ color: "var(--text-muted)" }}>→</span>
        <strong style={{ color: call.earlyOut ? "var(--good)" : "var(--text-secondary)" }}>
          {call.earlyOut ? "yes — return immediately, no vector touched" : "no — this is a real run"}
        </strong>
      </div>

      {call.earlyOut ? (
        <p className="viz-caption">
          One compare and out. Every JSON whitespace byte is ≤ 0x20 and every byte that may legally
          follow one is &gt; 0x20, so this settles the empty case without splatting a single
          constant. Across this sample it is the answer <strong>{early} of {calls.length}</strong>{" "}
          times — and on <code>canada.json</code>, which has no whitespace at all, it is the answer
          every time.
        </p>
      ) : (
        <>
          <div className="lanes">
            {call.lanes.map((lane) => (
              <div
                key={lane.offset}
                className={`lane ${lane.isWhitespace ? "ws" : ""} ${
                  lane.offset >= call.end ? "dim" : ""
                } ${lane.offset === call.end ? "terminator" : ""}`}
                title={`byte ${lane.offset}`}
              >
                <span className="glyph">{glyph(lane.byte)}</span>
                <span className="idx">{lane.offset}</span>
              </div>
            ))}
          </div>
          <Legend items={[{ color: "var(--series-7)", label: "whitespace (tab, LF, CR, space)" }]} />
          <p className="viz-caption">
            The compare did not settle it, so the run is scanned — {call.path === "vector" ? "SIMD16" : "one byte at a time, because fewer than 16 bytes remain"}
            . The run is <strong>{call.runLength}</strong> byte{call.runLength === 1 ? "" : "s"} long
            and the parser resumes at byte <strong>{call.end}</strong>.
          </p>
        </>
      )}

      <p className="viz-note">
        The width test in front of the vector body is not a tail guard. Fed one byte at a time,{" "}
        <code>to - from</code> is 1 at every call, and routing that through the vector body splats
        four constants to scan a single byte — which cost byte-by-byte Twitter 20%.
      </p>
    </div>
  );
}
