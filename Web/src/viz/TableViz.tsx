import { useState } from "react";
import type { TableTrace } from "../types";
import type { Cell, RowPhase, TapeMark } from "./common";
import {
  Bits,
  glyph,
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

/**
 * A membership test answered by indexing a table with part of the byte.
 *
 * Two kernels have this shape and the visual is shared: the whitespace scan (one table, indexed by
 * the low nibble, then a compare) and the number scan (two, one per nibble, ANDed). What both are
 * really demonstrating is why a table exists at all — `tbl` indexes sixteen entries with a whole
 * vector of indices in one instruction, so a question that needs four or six compares per lane
 * collapses to one or two lookups for the entire block.
 *
 * Stepped, the lookup stops being a static mapping and becomes an event: the index vector appears,
 * then the entries it fetched appear, and the table lights up in *both* directions — the sixteen
 * entries this one block reads, all at the same instant, which is the thing a per-lane compare
 * ladder cannot do.
 */
export function TableViz({ trace }: { trace: TableTrace }) {
  const [hover, setHover] = useState<number | null>(null);
  // One step to load, two per table (index, then lookup), one to combine.
  const steps = 2 + trace.tables.length * 2;
  const { index, setIndex, playing, play } = useSteps(steps, 1150);

  const at = (stage: number): RowPhase =>
    index === stage ? "now" : index > stage ? "past" : "future";
  /** Which table the current step is working on, or -1 outside the lookup steps. */
  const workingTable = index >= 1 && index <= trace.tables.length * 2 ? Math.floor((index - 1) / 2) : -1;

  const active = hover === null ? null : trace.lanes[hover];

  const laneCells: Cell[] = trace.lanes.map((l) => ({
    text: hex(l.byte),
    sub: glyph(l.byte),
    on: index === steps - 1 && l.hit,
    marked: l.lane === hover,
    title: `lane ${l.lane}`
  }));

  const indexCells = (which: number): Cell[] =>
    trace.lanes.map((l) => ({
      text: l.indices[which].toString(16).toUpperCase(),
      sub: String(l.lane),
      dim: true,
      marked: l.lane === hover
    }));

  const valueCells = (which: number): Cell[] =>
    trace.lanes.map((l) => ({
      text:
        trace.tables[which].format === "bits"
          ? l.values[which].toString(2).padStart(5, "0")
          : hex(l.values[which]),
      sub: String(l.lane),
      on: l.values[which] !== 0,
      marked: l.lane === hover
    }));

  const resultCells: Cell[] = trace.lanes.map((l) => ({
    text: l.hit ? "FF" : "00",
    sub: String(l.lane),
    on: l.hit,
    marked: l.lane === hover
  }));

  const firstMiss = trace.lanes.find((l) => !l.hit);

  // Every entry the block reads from a given table — sixteen simultaneous reads, one instruction.
  const touched = (which: number) => new Set(trace.lanes.map((l) => l.indices[which]));

  const marks: TapeMark[] = [{ from: 0, to: 16, kind: "window" }];
  if (index === steps - 1 && firstMiss) {
    marks.push({ from: firstMiss.lane, to: firstMiss.lane + 1, kind: "next" });
  }
  if (active) marks.push({ from: active.lane, to: active.lane + 1, kind: "cursor" });

  const onLane = (e: React.MouseEvent) => {
    const el = (e.target as HTMLElement).closest(".vec-lane");
    const parent = el?.parentElement;
    if (el && parent) setHover(Array.prototype.indexOf.call(parent.children, el));
  };

  return (
    <div className="viz" onMouseLeave={() => setHover(null)}>
      <StepBar
        index={index}
        count={steps}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Instruction"
      />

      <StepNote op={stepOp(trace, index, steps)}>{stepNote(trace, index, steps)}</StepNote>

      <InputTape
        bytes={trace.bytes}
        marks={marks}
        label={`${trace.kernel} — sample`}
        caption={
          active ? (
            <>
              Lane {active.lane} is byte {active.lane} of the input, <code>0x{hex(active.byte)}</code>{" "}
              ({glyph(active.byte)}).
            </>
          ) : index === steps - 1 && firstMiss ? (
            <>
              The outlined byte is where the run ends — byte <strong>{firstMiss.lane}</strong>. Bytes
              past it are in the register but not in the class.
            </>
          ) : (
            <>
              One load covers the first sixteen bytes. Everything below happens to all of them at
              once.
            </>
          )
        }
      />

      <p className="viz-caption" style={{ marginTop: 0 }}>
        {trace.summary}
      </p>

      <div className="replaces">
        <span className="tag">instead of</span>
        <code>{trace.replaces}</code>
      </div>

      {trace.tables.map((table, i) => (
        <TableStrip
          key={table.name}
          table={table}
          active={active ? active.indices[i] : undefined}
          touched={index >= 2 + i * 2 ? touched(i) : undefined}
          dim={index < 1 + i * 2}
        />
      ))}

      <div className="vec-stack" onMouseOver={onLane} onMouseLeave={() => setHover(null)}>
        <VectorRow op="ldr" note="16 bytes" cells={laneCells} phase={at(0)} epoch={index} />

        {trace.tables.map((table, i) => (
          <div key={table.name}>
            <VectorOp
              symbol={table.indexedBy.includes(">>") ? "»" : "&"}
              label={`${table.indexedBy} — the index vector`}
              phase={at(1 + i * 2)}
            />
            <VectorRow op="index" note={table.indexedBy} cells={indexCells(i)} phase={at(1 + i * 2)} />
            <VectorOp
              symbol="tbl"
              label={`one lookup, all sixteen lanes: ${table.name}`}
              phase={at(2 + i * 2)}
            />
            <VectorRow op="lookup" note={table.name} cells={valueCells(i)} phase={at(2 + i * 2)} />
          </div>
        ))}

        <VectorOp
          symbol={trace.combine === "equal" ? "==" : "&"}
          label={
            trace.combine === "equal"
              ? "cmeq — a lane is whitespace exactly when it equals what its own nibble fetched"
              : "vtstq_u8 — in the class when the two bitmasks share a set bit"
          }
          phase={at(steps - 1)}
        />
        <VectorRow op="in class" cells={resultCells} kind="mask" phase={at(steps - 1)} />
      </div>

      {active ? (
        <p className="viz-caption">
          Lane <strong>{active.lane}</strong> is <code>0x{hex(active.byte)}</code> (
          {glyph(active.byte)}).{" "}
          {trace.tables.map((table, i) => (
            <span key={table.name}>
              {table.indexedBy.replace("byte", "it")} is{" "}
              <code>{active.indices[i].toString(16).toUpperCase()}</code>, fetching{" "}
              {table.format === "bits" ? (
                <Bits value={active.values[i]} labels={table.bitLabels} />
              ) : (
                <code>0x{hex(active.values[i])}</code>
              )}
              {i < trace.tables.length - 1 ? "; " : ". "}
            </span>
          ))}
          {trace.combine === "equal"
            ? active.hit
              ? "That is the byte itself, so the lane is whitespace."
              : "That is not the byte, so the lane is not whitespace."
            : active.hit
              ? "The two share a set bit, so the byte is part of a number."
              : "They share no bit, so the number token ends here."}
        </p>
      ) : (
        <p className="viz-caption">
          Hover a lane to follow one byte into the table and back.{" "}
          {index === steps - 1 && firstMiss ? (
            <>
              The first lane the tables miss is <strong>{firstMiss.lane}</strong> — a{" "}
              <code>0x{hex(firstMiss.byte)}</code> ({glyph(firstMiss.byte)}) — and that is where the
              run ends.
            </>
          ) : workingTable >= 0 ? (
            <>
              {trace.tables[workingTable].name} is highlighted above; the marked entries are the ones
              this block reads.
            </>
          ) : null}
        </p>
      )}

      <p className="viz-note">
        <code>{trace.kernel}</code> · sample <code>{trace.sample}</code>
      </p>
      <VerifiedNote verified={trace.verified} />
    </div>
  );
}

function stepOp(trace: TableTrace, index: number, steps: number): string {
  if (index === 0) return "ldr";
  if (index === steps - 1) return trace.combine === "equal" ? "cmeq" : "vtstq_u8";
  return index % 2 === 1 ? (trace.tables[(index - 1) / 2].indexedBy.includes(">>") ? "ushr" : "and") : "tbl";
}

function stepNote(trace: TableTrace, index: number, steps: number) {
  if (index === 0) {
    return <>Sixteen bytes of the caller's buffer into a register. Nothing classified yet.</>;
  }
  if (index === steps - 1) {
    return trace.combine === "equal" ? (
      <>
        Compare the fetched entries against the original bytes. A lane is whitespace exactly when
        the table handed back the byte itself.
      </>
    ) : (
      <>
        Test the two fetched bitmasks against each other. A lane is a number byte when they share a
        set bit — and the first lane that does not is the end of the token.
      </>
    );
  }
  const which = Math.floor((index - 1) / 2);
  const table = trace.tables[which];
  return index % 2 === 1 ? (
    <>
      Build the index vector: <code>{table.indexedBy}</code> for every lane. This is one shift or one
      mask, not sixteen.
    </>
  ) : (
    <>
      One <code>tbl</code>. Sixteen lanes read sixteen entries of {table.name} simultaneously — the
      entries it touched are marked in the strip above.
    </>
  );
}
