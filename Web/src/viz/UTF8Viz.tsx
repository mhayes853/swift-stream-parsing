import { useState } from "react";
import type { UTF8Trace } from "../types";
import type { Cell } from "./common";
import { Bits, hex, TableStrip, VectorOp, VectorRow, VerifiedNote } from "./common";

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

/**
 * Keiser and Lemire's lookup validator, one block wide.
 *
 * The claim it rests on is that every UTF-8 error is visible in a window of two adjacent bytes —
 * so instead of walking sequences, three nibbles index three tables of error classes, the three
 * results are ANDed, and a lane is wrong exactly when something survives. The one fact that
 * *cannot* be seen in two adjacent bytes — a three or four byte lead requires a continuation two or
 * three lanes later — is XORed in from saturating subtractions on the shifted views.
 *
 * That XOR is the part worth watching: it both raises errors the lookups missed and cancels ones
 * the lookups raised, which is why the third byte of a three-byte sequence comes out clean.
 */
export function UTF8Viz({ trace }: { trace: UTF8Trace }) {
  const [lane, setLane] = useState<number | null>(null);
  const active = lane === null ? null : trace.lanes[lane];

  const cells = (pick: (l: UTF8Trace["lanes"][number]) => Cell): Cell[] =>
    trace.lanes.map((l) => ({ ...pick(l), marked: l.lane === lane }));

  const roles = Array.from(new Set(trace.lanes.map((l) => l.role)));

  return (
    <div className="viz" onMouseLeave={() => setLane(null)}>
      <p className="viz-caption" style={{ marginTop: 0 }}>
        One 16-byte block of <code>{trace.sample}</code>. Three lookups classify every lane at once;
        the sequences are never walked.
      </p>

      <div
        className="vec-stack"
        onMouseOver={(e) => {
          const el = (e.target as HTMLElement).closest(".vec-lane");
          const parent = el?.parentElement;
          if (el && parent) setLane(Array.prototype.indexOf.call(parent.children, el));
        }}
      >
        <VectorRow
          op="current"
          note="the block"
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
        />
      ))}

      <div
        className="vec-stack"
        onMouseOver={(e) => {
          const el = (e.target as HTMLElement).closest(".vec-lane");
          const parent = el?.parentElement;
          if (el && parent) setLane(Array.prototype.indexOf.call(parent.children, el));
        }}
      >
        {trace.tables.map((table, i) => (
          <VectorRow
            key={table.name}
            op={`tbl ${i + 1}`}
            note={table.indexedBy}
            cells={cells((l) => ({
              text: hex(l.values[i]),
              sub: String(l.lane),
              on: l.values[i] !== 0
            }))}
          />
        ))}
        <VectorOp symbol="&" label="and, and — three classifications, one surviving set of bits" />
        <VectorRow
          op="special"
          cells={cells((l) => ({ text: hex(l.special), sub: String(l.lane), on: l.special !== 0 }))}
        />
        <VectorRow
          op="mustContinue"
          note="qsub, qsub, orr, and"
          cells={cells((l) => ({
            text: hex(l.mustContinue),
            sub: String(l.lane),
            on: l.mustContinue !== 0,
            tone: "var(--warning)"
          }))}
        />
        <VectorOp symbol="^" label="eor — the fact two adjacent bytes cannot express" />
        <VectorRow
          op="error"
          note={trace.valid ? "all zero" : "non-zero"}
          cells={cells((l) => ({
            text: hex(l.error),
            sub: String(l.lane),
            on: l.error !== 0,
            tone: "var(--critical)"
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
