import { useState } from "react";
import type { UTF8Trace } from "../types";
import type { Cell, RowPhase, TapeMark } from "./common";
import {
  Bits,
  hex,
  InputTape,
  StepBar,
  StepNote,
  TableStrip,
  useSteps,
  VectorOp,
  VectorRow,
  VerifiedNote
} from "./common";

const ROLE_TONE: Record<string, string> = {
  ascii: "var(--text-muted)",
  continuation: "var(--series-3)",
  lead2: "var(--series-1)",
  lead3: "var(--series-2)",
  lead4: "var(--series-7)",
  invalid: "var(--critical)"
};

const ROLE_LABEL: Record<string, string> = {
  ascii: "ASCII",
  continuation: "continuation",
  lead2: "2-byte lead",
  lead3: "3-byte lead",
  lead4: "4-byte lead",
  invalid: "invalid"
};

/** The validator's instructions, in issue order. */
const OPS = [
  { op: "ldr", label: "load the block" },
  { op: "ldr", label: "load the same block one byte earlier" },
  { op: "tbl", label: "look up the first error class" },
  { op: "tbl", label: "look up the second" },
  { op: "tbl", label: "look up the third" },
  { op: "and", label: "keep only what all three flagged" },
  { op: "qsub", label: "derive the continuation requirement" },
  { op: "eor", label: "fold the structural fact into the lookups" }
] as const;

/**
 * Keiser and Lemire's lookup validator, one block wide.
 *
 * The claim it rests on is that every UTF-8 error is visible in a window of two adjacent bytes —
 * so instead of walking sequences, three nibbles index three tables of error classes, the three
 * results are ANDed, and a lane is wrong exactly when something survives. The one fact that
 * *cannot* be seen in two adjacent bytes — a three or four byte lead requires a continuation two or
 * three lanes later — is XORed in from saturating subtractions on the shifted views.
 *
 * That XOR is the part worth watching, and it is why this one is stepped: it both raises errors the
 * lookups missed and cancels ones the lookups raised. In this sample lane 5 comes out of the AND
 * flagged and out of the XOR clean, which is only legible if the two registers appear one after the
 * other rather than together.
 */
export function UTF8Viz({ trace }: { trace: UTF8Trace }) {
  const [lane, setLane] = useState<number | null>(null);
  const { index, setIndex, playing, play } = useSteps(OPS.length, 1250);
  const active = lane === null ? null : trace.lanes[lane];

  const at = (stage: number): RowPhase =>
    index === stage ? "now" : index > stage ? "past" : "future";

  const cells = (pick: (l: UTF8Trace["lanes"][number]) => Cell): Cell[] =>
    trace.lanes.map((l) => ({ ...pick(l), marked: l.lane === lane }));

  const roles = Array.from(new Set(trace.lanes.map((l) => l.role)));

  const onLane = (e: React.MouseEvent) => {
    const el = (e.target as HTMLElement).closest(".vec-lane");
    const parent = el?.parentElement;
    if (el && parent) setLane(Array.prototype.indexOf.call(parent.children, el));
  };

  // The two-byte window the whole method rests on: the lane, and the byte before it.
  const marks: TapeMark[] = [{ from: 0, to: 16, kind: "window" }];
  if (active) {
    if (active.lane > 0) marks.push({ from: active.lane - 1, to: active.lane, kind: "next" });
    marks.push({ from: active.lane, to: active.lane + 1, kind: "cursor" });
  }

  return (
    <div className="viz" onMouseLeave={() => setLane(null)}>
      <StepBar
        index={index}
        count={OPS.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Instruction"
      />

      <StepNote op={OPS[index].op}>
        {OPS[index].label} — {stepNote(trace, index, active)}
      </StepNote>

      <InputTape
        bytes={trace.bytes}
        marks={marks}
        label={`UTF-8 block of ${JSON.stringify(trace.sample)}`}
        caption={
          active ? (
            <>
              The filled byte is lane {active.lane}; the outlined one before it is the only other
              byte the lookups get to see. Everything the validator decides about this lane, it
              decides from those two.
            </>
          ) : (
            <>
              Thirteen bytes of text, padded to a full register. Hover a lane below to mark the
              two-byte window the tables are indexed by.
            </>
          )
        }
      />

      <div className="vec-stack" onMouseOver={onLane}>
        <VectorRow
          op="current"
          note="the block"
          phase={at(0)}
          cells={cells((l) => ({
            text: hex(l.byte),
            sub: String(l.lane),
            on: l.role !== "ascii",
            tone: ROLE_TONE[l.role],
            title: `${ROLE_LABEL[l.role]} 0x${hex(l.byte)}`
          }))}
        />
        <VectorRow
          op="previous1"
          note="shifted one lane"
          phase={at(1)}
          cells={cells((l) => ({ text: hex(l.previous1), sub: String(l.lane), dim: true }))}
        />
      </div>

      <p className="viz-caption">
        The previous-byte views are the same block re-loaded one, two and three bytes earlier —
        loads, not lane shifts. Shifting them in with <code>ext</code> instead measured 10% slower
        on the validator alone: the loads issue on the load ports, where <code>ext</code> competes
        with the kernel's own vector ALU work.
      </p>

      {trace.tables.map((table, i) => (
        <TableStrip
          key={table.name}
          table={table}
          active={active ? active.indices[i] : undefined}
          touched={index >= 2 + i ? new Set(trace.lanes.map((l) => l.indices[i])) : undefined}
          dim={index < 2 + i}
        />
      ))}

      <div className="vec-stack" onMouseOver={onLane}>
        {trace.tables.map((table, i) => (
          <VectorRow
            key={table.name}
            op={`tbl ${i + 1}`}
            note={table.indexedBy}
            phase={at(2 + i)}
            cells={cells((l) => ({
              text: hex(l.values[i]),
              sub: String(l.lane),
              on: l.values[i] !== 0
            }))}
          />
        ))}
        <VectorOp
          symbol="&"
          label="and, and — three classifications, one surviving set of bits"
          phase={at(5)}
        />
        <VectorRow
          op="special"
          phase={at(5)}
          cells={cells((l) => ({ text: hex(l.special), sub: String(l.lane), on: l.special !== 0 }))}
        />
        <VectorRow
          op="mustContinue"
          note="qsub, qsub, orr, and"
          phase={at(6)}
          cells={cells((l) => ({
            text: hex(l.mustContinue),
            sub: String(l.lane),
            on: l.mustContinue !== 0,
            tone: "var(--warning)"
          }))}
        />
        <VectorOp symbol="^" label="eor — the fact two adjacent bytes cannot express" phase={at(7)} />
        <VectorRow
          op="error"
          note={trace.valid ? "all zero" : "non-zero"}
          phase={at(7)}
          cells={cells((l) => ({
            text: hex(l.error),
            sub: String(l.lane),
            on: l.error !== 0,
            tone: "var(--critical)",
            // Where the XOR changed the verdict the lookups had reached.
            changed: l.error !== l.special
          }))}
          kind="mask"
        />
      </div>

      {active ? (
        <p className="viz-caption">
          Lane <strong>{active.lane}</strong> is <code>0x{hex(active.byte)}</code>, a{" "}
          <strong>{ROLE_LABEL[active.role]}</strong>. The byte before it is{" "}
          <code>0x{hex(active.previous1)}</code>, so the three lookups return{" "}
          {trace.tables.map((table, i) => (
            <span key={table.name}>
              <Bits value={active.values[i]} labels={table.bitLabels} />
              {i < 2 ? " · " : " "}
            </span>
          ))}
          and their AND is <code>0x{hex(active.special)}</code>.{" "}
          {active.mustContinue !== 0 ? (
            <>
              A lead two or three lanes back requires a continuation here, so the structural bit is
              set and XORs against the lookups —{" "}
              {active.error === 0
                ? "cancelling them exactly, which is what a correct sequence looks like."
                : "and something still survives."}
            </>
          ) : (
            <>No continuation is required at this lane, so the XOR leaves the lookups alone.</>
          )}{" "}
          {active.error === 0 ? (
            "Result: clean."
          ) : (
            <strong style={{ color: "var(--critical)" }}>
              Result: {active.classes.join(", ")}.
            </strong>
          )}
        </p>
      ) : (
        <p className="viz-caption">
          Hover a lane to follow it through all three tables.{" "}
          {trace.valid
            ? "Every lane comes out zero, so the block is valid — and the validator says only that."
            : "A lane survives, so the block is rejected."}{" "}
          An invalid run is rare, so it answers valid-or-not and nothing else; the parser's scalar
          walk then finds the offending byte, which is what keeps every error offset where the tests
          pin it.
        </p>
      )}

      <div className="legend">
        {roles.map((role) => (
          <span key={role}>
            <i style={{ background: ROLE_TONE[role] }} />
            {ROLE_LABEL[role]}
          </span>
        ))}
      </div>

      <p className="viz-note">
        On arm64 the three lookups are <code>tbl</code> and the whole block is one shim call. Every
        other platform recomputes the same classes with range compares — more instructions, and
        still none of the scalar walk's per-sequence branches.
      </p>
      <VerifiedNote verified={trace.verified} />
    </div>
  );
}

/** What the instruction on screen produced, said in terms of this block's actual values. */
function stepNote(trace: UTF8Trace, index: number, active: UTF8Trace["lanes"][number] | null) {
  const cancelled = trace.lanes.filter((l) => l.special !== 0 && l.error === 0);
  switch (index) {
    case 0:
      return <>sixteen bytes, no sequences walked and no lengths decoded.</>;
    case 1:
      return (
        <>
          the same bytes offset by one, so every lane can see its predecessor. Two of these are
          loaded as well, at two and three back.
        </>
      );
    case 2:
    case 3:
    case 4:
      return (
        <>
          <code>{trace.tables[index - 2].indexedBy}</code> indexes {trace.tables[index - 2].name};
          sixteen lanes, one instruction.
        </>
      );
    case 5:
      return (
        <>
          a lane keeps a bit only if all three tables set it. {trace.lanes.filter((l) => l.special !== 0).length} lane
          {trace.lanes.filter((l) => l.special !== 0).length === 1 ? " is" : "s are"} still flagged.
        </>
      );
    case 6:
      return (
        <>
          saturating subtracts on the two- and three-back views mark the lanes a longer lead
          <em> requires</em> to be continuations. Nothing here came from a table.
        </>
      );
    default:
      return cancelled.length > 0 ? (
        <>
          the XOR cancels lane{cancelled.length === 1 ? "" : "s"}{" "}
          {cancelled.map((l) => l.lane).join(", ")}: flagged by the lookups, required by the
          structure, so the two agree and the lane is clean.{" "}
          {active ? "" : "Hover it to see both values."}
        </>
      ) : (
        <>the XOR raises what the lookups could not see and cancels what they over-flagged.</>
      );
  }
}
