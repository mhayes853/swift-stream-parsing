import { useState } from "react";
import type { TableTrace } from "../types";
import type { Cell } from "./common";
import { Bits, glyph, hex, TableStrip, VectorRow, VectorOp, VerifiedNote } from "./common";

/**
 * A membership test answered by indexing a table with part of the byte.
 *
 * Two kernels have this shape and the visual is shared: the whitespace scan (one table, indexed by
 * the low nibble, then a compare) and the number scan (two, one per nibble, ANDed). What both are
 * really demonstrating is why a table exists at all — `tbl` indexes sixteen entries with a whole
 * vector of indices in one instruction, so a question that needs four or six compares per lane
 * collapses to one or two lookups for the entire block.
 *
 * Hovering a lane lights the entry it reads, in both directions, because the mapping is the thing
 * being taught.
 */
export function TableViz({ trace }: { trace: TableTrace }) {
  const [lane, setLane] = useState<number | null>(null);
  const active = lane === null ? null : trace.lanes[lane];

  const laneCells: Cell[] = trace.lanes.map((l) => ({
    text: hex(l.byte),
    sub: glyph(l.byte),
    on: l.hit,
    marked: l.lane === lane,
    title: `lane ${l.lane}`
  }));

  const indexCells = (which: number): Cell[] =>
    trace.lanes.map((l) => ({
      text: l.indices[which].toString(16).toUpperCase(),
      sub: String(l.lane),
      dim: true,
      marked: l.lane === lane
    }));

  const valueCells = (which: number): Cell[] =>
    trace.lanes.map((l) => ({
      text: trace.tables[which].format === "bits" ? l.values[which].toString(2).padStart(5, "0") : hex(l.values[which]),
      sub: String(l.lane),
      on: l.values[which] !== 0,
      marked: l.lane === lane
    }));

  const resultCells: Cell[] = trace.lanes.map((l) => ({
    text: l.hit ? "FF" : "00",
    sub: String(l.lane),
    on: l.hit,
    marked: l.lane === lane
  }));

  const firstMiss = trace.lanes.find((l) => !l.hit);

  return (
    <div
      className="viz"
      onMouseLeave={() => setLane(null)}
    >
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
        />
      ))}

      <div className="vec-stack" onMouseLeave={() => setLane(null)}>
        <div onMouseOver={(e) => {
          const el = (e.target as HTMLElement).closest(".vec-lane");
          if (!el) return;
          const parent = el.parentElement;
          if (parent) setLane(Array.prototype.indexOf.call(parent.children, el));
        }}>
          <VectorRow op="ldr" note="16 bytes" cells={laneCells} />
        </div>

        {trace.tables.map((table, i) => (
          <div key={table.name}>
            <VectorOp
              symbol={i === 0 ? "»" : "&"}
              label={`${table.indexedBy} — the index vector`}
            />
            <VectorRow op="index" note={table.indexedBy} cells={indexCells(i)} />
            <VectorOp symbol="tbl" label={`one lookup, all sixteen lanes: ${table.name}`} />
            <VectorRow op="lookup" note={table.name} cells={valueCells(i)} />
          </div>
        ))}

        <VectorOp
          symbol={trace.combine === "equal" ? "==" : "&"}
          label={
            trace.combine === "equal"
              ? "cmeq — a lane is whitespace exactly when it equals what its own nibble fetched"
              : "vtstq_u8 — in the class when the two bitmasks share a set bit"
          }
        />
        <VectorRow op="in class" cells={resultCells} kind="mask" />
      </div>

      {active && (
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
      )}
      {!active && (
        <p className="viz-caption">
          Hover a lane to follow it into the table.{" "}
          {firstMiss ? (
            <>
              The first lane the tables miss is <strong>{firstMiss.lane}</strong> — a{" "}
              <code>0x{hex(firstMiss.byte)}</code> ({glyph(firstMiss.byte)}) — and that is where the
              run ends.
            </>
          ) : (
            <>Every lane in this block is in the class, so the scan takes the whole block and moves on.</>
          )}
        </p>
      )}

      <p className="viz-note">
        <code>{trace.kernel}</code> · sample <code>{trace.sample}</code>
      </p>
      <VerifiedNote verified={trace.verified} />
    </div>
  );
}
