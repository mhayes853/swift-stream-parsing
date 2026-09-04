import type { StringRunTrace } from "../types";
import type { Cell } from "./common";
import { glyph, hex, splat, StepBar, useSteps, VectorOp, VectorRow, VerifiedNote } from "./common";

/**
 * `streamStringRun`, block by block, as the vector pipeline it is.
 *
 * The old version of this drew one row of coloured bytes and said "three compares happen". That
 * hides the thing worth understanding: the three compares are *three separate 16-lane registers*
 * that exist at the same time, each produced by comparing the loaded block against a splatted
 * constant, and the OR that folds them is one more vector instruction rather than a loop. Sixteen
 * bytes are classified in the time a scalar loop classifies one, and the reader should be able to
 * count the instructions off the picture.
 */
export function StringRunViz({ trace }: { trace: StringRunTrace }) {
  const steps = trace.blocks.length;
  const { index, setIndex, playing, play } = useSteps(steps, 1800);
  const block = trace.blocks[index];

  if (!block) return null;

  const bytes: Cell[] = block.bytes.map((byte, lane) => ({
    text: hex(byte),
    sub: glyph(byte),
    dim: block.anyHit && lane > block.hitLane,
    title: `lane ${lane}: 0x${hex(byte)}`
  }));

  const maskRow = (set: boolean[], tone: string): Cell[] =>
    set.map((on, lane) => ({
      text: on ? "FF" : "00",
      sub: String(lane),
      on,
      tone,
      dim: block.anyHit && lane > block.hitLane
    }));

  const hitCells: Cell[] = block.hit.map((on, lane) => ({
    text: on ? "FF" : "00",
    sub: String(lane),
    on,
    marked: lane === block.hitLane,
    dim: block.anyHit && lane > block.hitLane
  }));

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={steps}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Vector block"
      />

      <p className="viz-caption" style={{ marginTop: 0 }}>
        Block at byte {block.offset} of{" "}
        <code style={{ fontSize: 12 }}>{trace.sample}</code>. Every row below is one 128-bit
        register; a lane only ever moves straight down.
      </p>

      <div className="vec-stack">
        <VectorRow op="ldr" note="16 bytes" cells={bytes} />

        <VectorRow op="dup" note={'splat "'} cells={splat("22")} />
        <VectorOp symbol="==" label="cmeq — sixteen compares, one instruction" />
        <VectorRow op="isQuote" cells={maskRow(block.isQuote, "var(--series-1)")} kind="mask" />

        <VectorRow op="dup" note={"splat \\"} cells={splat("5C")} />
        <VectorOp symbol="==" label="cmeq" />
        <VectorRow op="isBackslash" cells={maskRow(block.isBackslash, "var(--series-2)")} kind="mask" />

        <VectorRow op="dup" note="splat 0x20" cells={splat("20")} />
        <VectorOp symbol="&lt;" label="cmlo — the control-byte floor" />
        <VectorRow op="isControl" cells={maskRow(block.isControl, "var(--series-3)")} kind="mask" />

        <VectorOp symbol="|" label="orr, orr — fold the three into one" />
        <VectorRow op="hit" note="the answer" cells={hitCells} kind="mask" />
      </div>

      <p className="viz-caption">
        {block.anyHit ? (
          <>
            The fold is non-zero, so the run ends in this block. The terminating lane is{" "}
            <strong>{block.hitLane}</strong> — a <code>0x{hex(block.bytes[block.hitLane])}</code>,
            which is{" "}
            {block.isQuote[block.hitLane]
              ? "the closing quote"
              : block.isBackslash[block.hitLane]
                ? "an escape"
                : "a control byte"}
            . Finding <em>which</em> lane is its own instruction; that is the next step in the
            chart.
          </>
        ) : (
          <>
            All sixteen lanes are 0x00, so none of the three classes fired and every byte is string
            content. The block is ORed into the running <code>scanned</code> accumulator — carrying
            the high-bit question forward for free — and the cursor advances a full sixteen bytes.
          </>
        )}
      </p>

      <div className="vec-stack" style={{ marginTop: 14 }}>
        <VectorRow
          op="scanned"
          note="|= this block"
          cells={block.scannedAfter.map((byte, lane) => ({
            text: hex(byte),
            sub: String(lane),
            on: byte >= 0x80
          }))}
        />
      </div>
      <p className="viz-caption">
        The same load answers a second question. <code>scanned</code> accumulates the bytes with
        <code> |</code>, and one high-bit test at the end says whether the run was pure ASCII —{" "}
        {block.nonASCIIAfter ? "so far it is not" : "so far it is"}. When a terminator lands
        mid-block the lanes past it are masked out <em>before</em> they reach the accumulator, which
        is what makes the answer exact rather than conservative.
      </p>

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
