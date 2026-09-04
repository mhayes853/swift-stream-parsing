import type { TableTrace, WhitespaceTrace } from "../types";
import type { TapeMark } from "./common";
import {
  glyph,
  hex,
  InputTape,
  Legend,
  StepBar,
  StepNote,
  TableStrip,
  useSteps
} from "./common";

/**
 * `streamWhitespaceEnd` at each of the call sites the parser makes it.
 *
 * The point of this one is the *branch*, not the scan: a single compare against 0x20 settles the
 * no-whitespace case, and the vector body lives behind a call so its register pressure never
 * reaches the parse loop. So the animation gives that compare a step of its own — most call sites
 * end there, and watching the timeline spend most of its length on one instruction is the finding.
 */
export function WhitespaceViz({ trace, table }: { trace: WhitespaceTrace; table: TableTrace }) {
  // Two steps at a call site that scans, one at a call site the compare settles.
  const script = trace.calls.flatMap((call, i) =>
    call.earlyOut ? [{ call: i, stage: 0 }] : [{ call: i, stage: 0 }, { call: i, stage: 1 }]
  );
  const { index, setIndex, playing, play } = useSteps(script.length, 950);
  const here = script[index];
  if (!here) return null;
  const call = trace.calls[here.call];
  const scanning = here.stage === 1;

  const early = trace.calls.filter((c) => c.earlyOut).length;

  const marks: TapeMark[] = [{ from: 0, to: call.from, kind: "done" }];
  if (scanning) {
    marks.push({ from: call.from, to: Math.min(call.from + 16, call.to), kind: "window" });
    marks.push({ from: call.from, to: call.end, kind: "cursor" });
    marks.push({ from: call.end, to: call.end + 1, kind: "next" });
  } else {
    // The early-out returns *at* the byte it tested, so the byte the call reads and the byte the
    // parser resumes at are the same one; drawing it twice would only make it look like two.
    marks.push({ from: call.from, to: call.from + 1, kind: "cursor" });
  }

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={script.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Instruction"
      />

      <StepNote op={scanning ? (call.path === "vector" ? "tbl" : "ldrb") : "cmp"}>
        {scanning ? (
          <>
            Call {here.call + 1} of {trace.calls.length}, from byte {call.from} — scan the run{" "}
            {call.path === "vector" ? "sixteen bytes at a time" : "one byte at a time"} and report
            where it ends.
          </>
        ) : (
          <>
            Call {here.call + 1} of {trace.calls.length}, from byte {call.from} — one compare of the
            first byte against 0x20.
          </>
        )}
      </StepNote>

      <InputTape
        bytes={trace.bytes}
        marks={marks}
        label={`streamWhitespaceEnd(from: ${call.from})`}
        caption={
          scanning ? (
            <>
              Filled is the whitespace run this call consumed — {call.runLength} byte
              {call.runLength === 1 ? "" : "s"}. The outlined byte after it is where the parser
              resumes.
            </>
          ) : call.earlyOut ? (
            <>
              The filled byte is the only one this call reads. It is <code>0x{hex(call.firstByte)}</code>{" "}
              ({glyph(call.firstByte)}), above 0x20, so the call returns here and never looks at a
              second byte — the byte it read and the byte the parser resumes at are the same one.
            </>
          ) : (
            <>
              The filled byte is <code>0x{hex(call.firstByte)}</code> ({glyph(call.firstByte)}) — at
              or below 0x20, so the compare cannot settle it and the scan below runs.
            </>
          )
        }
      />

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
            background: call.earlyOut
              ? "color-mix(in srgb, var(--good) 22%, var(--surface-1))"
              : "var(--surface-1)"
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
          constant. Across this sample it is the answer <strong>{early} of {trace.calls.length}</strong>{" "}
          times — and on <code>canada.json</code>, which has no whitespace at all, it is the answer
          every time.
        </p>
      ) : (
        <>
          <div className="lanes">
            {call.lanes.map((lane) => (
              <div
                key={lane.offset}
                className={`lane ${scanning && lane.isWhitespace ? "ws" : ""} ${
                  !scanning || lane.offset >= call.end ? "dim" : ""
                } ${scanning && lane.offset === call.end ? "terminator" : ""}`}
                title={`byte ${lane.offset}`}
              >
                <span className="glyph">{glyph(lane.byte)}</span>
                <span className="idx">{lane.offset}</span>
              </div>
            ))}
          </div>
          <Legend items={[{ color: "var(--series-7)", label: "whitespace (tab, LF, CR, space)" }]} />
          {call.path === "vector" && <TableStrip table={table.tables[0]} dim={!scanning} />}
          <p className="viz-caption">
            {scanning ? (
              <>
                The compare did not settle it, so the run is scanned —{" "}
                {call.path === "vector"
                  ? "SIMD16, using the lookup above"
                  : "one byte at a time, because fewer than 16 bytes remain"}
                . The run is <strong>{call.runLength}</strong> byte
                {call.runLength === 1 ? "" : "s"} long and the parser resumes at byte{" "}
                <strong>{call.end}</strong>.
              </>
            ) : (
              <>
                Below 0x20, so the fast answer is unavailable and the call falls through to the scan
                — the next step. The window is loaded but nothing in it has been classified.
              </>
            )}
          </p>
        </>
      )}

      <div className="bitmap">
        <div className="bitmap-head">
          <strong>streamWhitespaceBitmap</strong>
          <code>(0x0000_0001_0000_2600 &gt;&gt; byte) &amp; 1</code>
        </div>
        <div className="bitmap-bits">
          {Array.from({ length: 64 }, (_, bit) => {
            const set = [0x09, 0x0a, 0x0d, 0x20].includes(bit);
            const isCurrent = call.firstByte === bit;
            return (
              <i
                key={bit}
                className={`${set ? "on" : ""} ${isCurrent ? "cur" : ""}`}
                title={`bit ${bit} — 0x${hex(bit)}${set ? " (whitespace)" : ""}`}
              />
            );
          })}
        </div>
        <p className="table-note">
          The scalar answer to the same question, and a lookup with no table: the four whitespace
          bytes all sit below 64, so membership is one shift and one <code>and</code> on a register
          the compiler already materialises.{" "}
          {call.firstByte < 64 ? (
            <>
              The ringed bit is this call's first byte, 0x{hex(call.firstByte)}.
            </>
          ) : (
            <>
              This call's first byte is 0x{hex(call.firstByte)}, past bit 63 — which is the case the
              shift has to survive.
            </>
          )}{" "}
          Swift's shift is a smart shift — an over-shift yields zero rather than trapping — which
          costs one <code>cmp</code>/<code>ccmp</code> pair against 63, because arm64's own shift
          masks the amount to six bits and would alias byte 64 onto byte 0.
        </p>
      </div>

      <p className="viz-note">
        The width test in front of the vector body is not a tail guard. Fed one byte at a time,{" "}
        <code>to - from</code> is 1 at every call, and routing that through the vector body splats
        four constants to scan a single byte — which cost byte-by-byte Twitter 20%.
      </p>
    </div>
  );
}
