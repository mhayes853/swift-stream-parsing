import type { StringRunTrace } from "../types";
import type { Cell, RowPhase, TapeMark } from "./common";
import {
  diff,
  glyph,
  hex,
  InputTape,
  splat,
  StepBar,
  StepNote,
  useSteps,
  VectorOp,
  VectorRow,
  VerifiedNote
} from "./common";

/**
 * `streamStringRun`, block by block, as the vector pipeline it is.
 *
 * Two things are being shown at once and they are deliberately coupled. The stack is the kernel:
 * three compares against splatted constants produce three separate 16-lane registers, and one OR
 * folds them. The tape above it is the caller's buffer, so every step can also say *which* bytes it
 * is looking at — a vector load is sixteen bytes of the input, and the reader should be able to
 * point at them.
 *
 * Stepping is per operation rather than per block. A block drawn all at once shows the answer but
 * not the work; drawn one instruction at a time, the register that appears is exactly what that
 * instruction produced.
 */

/** The kernel's instructions, in issue order. One step each, repeated for every block. */
const OPS = [
  { op: "ldr", note: "load sixteen bytes of the caller's buffer into a register" },
  { op: "cmeq", note: "compare all sixteen against a splatted 0x22" },
  { op: "cmeq", note: "compare all sixteen against a splatted 0x5C" },
  { op: "cmlo", note: "compare all sixteen against a splatted 0x20" },
  { op: "orr", note: "fold the three masks into one" },
  { op: "orr", note: "accumulate the bytes for the ASCII question" }
] as const;

export function StringRunViz({ trace }: { trace: StringRunTrace }) {
  const perBlock = OPS.length;
  const steps = trace.blocks.length * perBlock;
  const { index, setIndex, playing, play } = useSteps(steps, 950);

  const which = Math.floor(index / perBlock);
  const op = index % perBlock;
  const block = trace.blocks[which];
  if (!block) return null;

  /** Where a row sits on the timeline: produced by this step, already produced, or not yet. */
  const at = (stage: number): RowPhase => (op === stage ? "now" : op > stage ? "past" : "future");

  const bytes: Cell[] = block.bytes.map((byte, lane) => ({
    text: hex(byte),
    sub: glyph(byte),
    dim: op >= 4 && block.anyHit && lane > block.hitLane,
    title: `lane ${lane}: 0x${hex(byte)}`
  }));

  const maskRow = (set: boolean[], tone: string): Cell[] =>
    set.map((on, lane) => ({
      text: on ? "FF" : "00",
      sub: String(lane),
      on,
      tone,
      dim: op >= 4 && block.anyHit && lane > block.hitLane
    }));

  const hitCells: Cell[] = block.hit.map((on, lane) => ({
    text: on ? "FF" : "00",
    sub: String(lane),
    on,
    marked: lane === block.hitLane,
    dim: block.anyHit && lane > block.hitLane
  }));

  // The accumulator is the one register that is *updated* rather than produced, so its changed
  // lanes are pulsed against its previous value — which for the first block is the zero it starts
  // at, so the lanes the first OR filled in pulse too.
  const before =
    which > 0 ? trace.blocks[which - 1].scannedAfter : new Array(block.scannedAfter.length).fill(0);
  const changed = diff(block.scannedAfter, before);
  const scannedCells: Cell[] = block.scannedAfter.map((byte, lane) => ({
    text: hex(byte),
    sub: String(lane),
    on: byte >= 0x80,
    changed: changed[lane]
  }));

  const marks: TapeMark[] = [
    { from: 0, to: block.offset, kind: "done" },
    { from: block.offset, to: block.offset + 16, kind: "window" }
  ];
  if (op >= 4 && block.anyHit) {
    marks.push({ from: block.offset + block.hitLane, to: block.offset + block.hitLane + 1, kind: "cursor" });
  }

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={steps}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Instruction"
      />

      <StepNote op={OPS[op].op}>
        Block {which + 1} of {trace.blocks.length}, bytes {block.offset}–{block.offset + 15} —{" "}
        {OPS[op].note}.
      </StepNote>

      <InputTape
        bytes={trace.bytes}
        marks={marks}
        label={`streamStringRun("${trace.sample}")`}
        caption={
          <>
            Blue is the sixteen bytes in the register right now; the rule every sixteen bytes is
            where one load ends and the next begins.{" "}
            {op >= 4 && block.anyHit ? (
              <>
                The filled byte is lane <strong>{block.hitLane}</strong>, the terminator this block
                found.
              </>
            ) : (
              <>The scan advances a whole register at a time, not a byte at a time.</>
            )}
          </>
        }
      />

      <div className="vec-stack">
        <VectorRow op="ldr" note="16 bytes" cells={bytes} phase={at(0)} epoch={which} />

        <VectorRow op="dup" note={'splat "'} cells={splat("22")} phase={at(1)} />
        <VectorOp symbol="==" label="cmeq — sixteen compares, one instruction" phase={at(1)} />
        <VectorRow
          op="isQuote"
          cells={maskRow(block.isQuote, "var(--series-1)")}
          kind="mask"
          phase={at(1)}
          epoch={which}
        />

        <VectorRow op="dup" note={"splat \\"} cells={splat("5C")} phase={at(2)} />
        <VectorOp symbol="==" label="cmeq" phase={at(2)} />
        <VectorRow
          op="isBackslash"
          cells={maskRow(block.isBackslash, "var(--series-2)")}
          kind="mask"
          phase={at(2)}
          epoch={which}
        />

        <VectorRow op="dup" note="splat 0x20" cells={splat("20")} phase={at(3)} />
        <VectorOp symbol="&lt;" label="cmlo — the control-byte floor" phase={at(3)} />
        <VectorRow
          op="isControl"
          cells={maskRow(block.isControl, "var(--series-3)")}
          kind="mask"
          phase={at(3)}
          epoch={which}
        />

        <VectorOp symbol="|" label="orr, orr — fold the three into one" phase={at(4)} />
        <VectorRow op="hit" note="the answer" cells={hitCells} kind="mask" phase={at(4)} epoch={which} />

        <VectorOp symbol="|" label="orr — the same load, accumulated" phase={at(5)} />
        <VectorRow
          op="scanned"
          note="|= this block"
          cells={scannedCells}
          phase={at(5)}
          epoch={which}
        />
      </div>

      <p className="viz-caption">{caption(block, op, which)}</p>

      <p className="viz-note">
        Result: end {trace.end}, {trace.containsNonASCII ? "contains non-ASCII" : "ASCII only"}.
        SIMD16 was measured against SWAR and SIMD32 at four run lengths and is fastest at all of
        them: SWAR loses to plain scalar below about twelve bytes, and a 32-byte vector lowers to
        two NEON operations plus a recombine, because the register is 128 bits wide.
      </p>
      <VerifiedNote verified={trace.verified} />
    </div>
  );
}

/** What the step on screen just did, in the kernel's terms rather than the picture's. */
function caption(block: StringRunTrace["blocks"][number], op: number, which: number) {
  switch (op) {
    case 0:
      return (
        <>
          One <code>ldr</code> brings bytes {block.offset}–{block.offset + 15} into a 128-bit
          register. Nothing has been classified yet; the next three steps each ask one question of
          all sixteen at once.
        </>
      );
    case 1:
      return (
        <>
          <code>vdupq_n_u8(0x22)</code> puts a quote in every lane and <code>cmeq</code> compares
          them, writing 0xFF where the lane matched.{" "}
          {block.isQuote.some(Boolean)
            ? `Lane ${block.isQuote.indexOf(true)} is the closing quote.`
            : "No lane matched, so the closing quote is not in this block."}
        </>
      );
    case 2:
      return (
        <>
          The same load, a second constant. The mask from the previous step is untouched — three
          compares means three live registers, which is why the fold below can be one instruction
          instead of a loop.{" "}
          {block.isBackslash.some(Boolean)
            ? `Lane ${block.isBackslash.indexOf(true)} is a backslash, so an escape starts there.`
            : "No escape in this block."}
        </>
      );
    case 3:
      return (
        <>
          <code>cmlo</code> — unsigned less-than against 0x20. Control bytes are illegal unescaped
          inside a string, and testing for them costs the same one instruction as testing for a
          quote.{" "}
          {block.isControl.some(Boolean)
            ? `Lane ${block.isControl.indexOf(true)} is below 0x20.`
            : "None here."}
        </>
      );
    case 4:
      return block.anyHit ? (
        <>
          Two <code>orr</code>s fold the three masks into one. It is non-zero, so the run ends in
          this block: the terminating lane is <strong>{block.hitLane}</strong>, a{" "}
          <code>0x{hex(block.bytes[block.hitLane])}</code>, which is{" "}
          {block.isQuote[block.hitLane]
            ? "the closing quote"
            : block.isBackslash[block.hitLane]
              ? "an escape"
              : "a control byte"}
          . Finding <em>which</em> lane is its own instruction; that is the next node in the chart.
        </>
      ) : (
        <>
          The fold is all zeros, so none of the three classes fired and every byte is string
          content. The cursor advances a full sixteen bytes and the loop takes another block.
        </>
      );
    default:
      return (
        <>
          The same load answers a second question. <code>scanned</code> accumulates the bytes with
          <code> |</code>, and one high-bit test at the end says whether the run was pure ASCII —{" "}
          {block.nonASCIIAfter ? "so far it is not" : "so far it is"}.{" "}
          {which === 0
            ? "Nothing has been ORed into it before this, so every lane changed."
            : "The pulsed lanes are the ones this block changed."}{" "}
          When a terminator lands mid-block the lanes past it are masked out <em>before</em> they
          reach the accumulator, which is what makes the answer exact rather than conservative.
        </>
      );
  }
}
