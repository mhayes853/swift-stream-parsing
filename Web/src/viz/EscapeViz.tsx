import { useState } from "react";
import type { EscapeTrace } from "../types";
import type { TapeMark } from "./common";
import { glyph, hex, InputTape, StepBar, StepNote, useSteps, VerifiedNote } from "./common";

/**
 * `streamSimpleEscapeTable` — the smallest lookup in the parser, and the one whose *sentinel* is
 * the interesting part.
 *
 * A direct 128-byte map from the character after the backslash to the byte it decodes to. Zero
 * means "not a simple escape", and that costs nothing extra because no valid simple escape decodes
 * to NUL — so one table answers both "is this legal" and "what is it".
 *
 * Three steps, because there are exactly three: read the byte after the backslash, index the map
 * with it, and either write the entry out or fail. The whole map is drawn, and the eight lit cells
 * are all of it — the recorder asked the shipped decoder about all 128 indices, so a ninth escape
 * added to the parser would light a ninth cell here without anyone editing this file.
 */
const OPS = [
  { op: "ldrb", label: "read the byte after the backslash" },
  { op: "ldrb", label: "index the map with it — one load, no compares" },
  { op: "strb", label: "write the decoded byte, or fail" }
] as const;

export function EscapeViz({ trace }: { trace: EscapeTrace }) {
  const [which, setWhich] = useState(0);
  const { index, setIndex, playing, play } = useSteps(OPS.length, 1200);
  const entry = trace.entries[which];
  if (!entry) return null;

  const decoded = entry.decoded;
  const bytes = [0x5c, entry.byte];
  const marks: TapeMark[] = [{ from: 0, to: 1, kind: "done" }];
  if (index >= 1) marks.push({ from: 1, to: 2, kind: "cursor" });
  else marks.push({ from: 1, to: 2, kind: "window" });

  return (
    <div className="viz">
      <div className="chip-row">
        {trace.entries.map((e, i) => (
          <button
            key={e.byte}
            className={`chip ${i === which ? "active" : ""}`}
            onClick={() => {
              setWhich(i);
              setIndex(0);
            }}
          >
            {e.source}
          </button>
        ))}
      </div>

      <StepBar
        index={index}
        count={OPS.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Instruction"
      />

      <StepNote op={OPS[index].op}>
        {OPS[index].label}
        {index === 1 ? (
          <>
            {" "}
            — index <code>0x{hex(entry.byte)}</code> holds{" "}
            {decoded === undefined ? (
              <>
                the sentinel <code>0x00</code>
              </>
            ) : (
              <code>0x{hex(decoded)}</code>
            )}
            .
          </>
        ) : index === 2 ? (
          decoded === undefined ? (
            <> — zero, so this is not a legal escape and the parser reports the error.</>
          ) : (
            <>
              {" "}
              — <code>{glyph(decoded)}</code> goes straight into the destination; no intermediate
              string is built.
            </>
          )
        ) : (
          <>
            {" "}
            — the backslash is already consumed, so the byte at the cursor is the whole input to
            this lookup.
          </>
        )}
      </StepNote>

      <InputTape
        bytes={bytes}
        marks={marks}
        blockSize={0}
        label={`the escape ${entry.source}`}
        caption={
          <>
            Two bytes of the string body. The backslash is behind the cursor; the filled byte is the
            one that indexes the map, and it is the only thing the lookup sees.
          </>
        }
      />

      {/* The whole table, four rows of thirty-two. The lit cells are its entire content. */}
      <div className="escape-map-wrap">
        <div className="table-head">
          <strong>streamSimpleEscapeTable</strong>
          <code>128 bytes, indexed by the byte after the backslash</code>
        </div>
        <div className={`escape-map ${index >= 1 ? "live" : "dim"}`}>
          {trace.map.map((value, i) => (
            <i
              key={i}
              className={`emap ${value !== 0 ? "on" : ""} ${index >= 1 && i === entry.byte ? "cur" : ""}`}
              title={`index 0x${hex(i)} (${glyph(i)}) → ${value === 0 ? "sentinel 0x00" : `0x${hex(value)}`}`}
            >
              {value !== 0 ? glyph(value) : ""}
            </i>
          ))}
        </div>
        <p className="table-note">
          Eight non-zero cells out of 128, recovered by asking the shipped decoder about every
          index. The sentinel is why there is no second table: a legal escape can decode to
          anything except NUL, so zero is free to mean "no escape here", and the one load answers
          both questions at once.
        </p>
      </div>

      <div className={`escape-result ${index < 2 ? "pending" : decoded === undefined ? "bad" : "good"}`}>
        {index < 2 ? (
          <span>waiting on the lookup</span>
        ) : decoded === undefined ? (
          <span>
            <strong>0x00</strong> — {entry.meaning}
          </span>
        ) : (
          <span>
            <strong>0x{hex(decoded)}</strong> {glyph(decoded)} — {entry.meaning}
          </span>
        )}
      </div>

      <table className="escape-table">
        <thead>
          <tr>
            <th>source</th>
            <th>index</th>
            <th>entry</th>
            <th>decodes to</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {trace.entries.map((e, i) => (
            <tr
              key={e.byte}
              className={`${e.decoded === undefined ? "miss" : ""} ${i === which ? "here" : ""}`}
              onClick={() => {
                setWhich(i);
                setIndex(0);
              }}
            >
              <td>
                <code>{e.source}</code>
              </td>
              <td className="mono">0x{hex(e.byte)}</td>
              <td className="mono">
                {e.decoded === undefined ? <span className="sentinel">00</span> : hex(e.decoded)}
              </td>
              <td className="mono">{e.decoded === undefined ? "—" : glyph(e.decoded)}</td>
              <td className="meaning">{e.meaning}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <p className="viz-note">
        The table is a <code>StaticString</code>, so the 128 bytes live in read-only storage rather
        than being built into an <code>Array</code> at startup — which matters to the parser's
        one-allocation fast path and to Embedded Swift, where there may be no allocator at all. The
        decoded bytes go straight into the destination, and
        <code> \u</code> is handled before the table is consulted because four more bytes cannot be
        represented by a one-byte result.
      </p>
      <VerifiedNote verified={trace.verified} />
    </div>
  );
}
