import type { StringRunTrace } from "../types";
import type { Cell, RowPhase, TapeMark } from "./common";
import { InputTape, StepBar, StepNote, useSteps, VectorRow } from "./common";

/**
 * `streamFirstHitLane` — getting a lane index out of a vector.
 *
 * This is the step every first-hit problem in the scanners runs into: the compare has already
 * answered "which lanes", in a vector register, and the scalar code needs "which is the first", in
 * a general register. The portable spelling reads the mask's own storage as two 64-bit words and
 * counts trailing zeros; the arm64 spelling narrows each lane to a nibble with `shrn` and counts
 * once. Both are shown because both ship, and they are stepped in sequence so the second reads as
 * a different spelling of the same question rather than as an extra stage.
 *
 * The arithmetic at the end is the branchless combination, and it is the point of the whole
 * function: a terminator's lane is unpredictable by nature, so there is nothing here to predict.
 */

const OPS = [
  { op: "mask", note: "the fold from the compares, still in a vector register" },
  { op: "tzcnt", note: "read the low half as a 64-bit word and count trailing zeros" },
  { op: "tzcnt", note: "the same for the high half" },
  { op: "shrn", note: "the arm64 spelling: narrow sixteen lanes to sixteen nibbles, count once" },
  { op: "lane", note: "combine the two counts without a branch" }
] as const;

export function MovemaskViz({ trace }: { trace: StringRunTrace }) {
  const blocks = trace.blocks;
  const perBlock = OPS.length;
  const { index, setIndex, playing, play } = useSteps(blocks.length * perBlock, 1000);

  const which = Math.floor(index / perBlock);
  const op = index % perBlock;
  const block = blocks[which];
  if (!block) return null;

  const at = (stage: number): RowPhase => (op === stage ? "now" : op > stage ? "past" : "future");

  // The mask's storage: 0xFF where the lane hit. Reading it as two little-endian 64-bit words puts
  // each lane in its own byte, which is why the lane index is a trailing-zero count over eight.
  const maskBytes = block.hit.map((on) => (on ? 0xff : 0x00));
  const word = (half: number[]) =>
    half
      .map((b) => b.toString(16).toUpperCase().padStart(2, "0"))
      .reverse()
      .join("");
  const low = maskBytes.slice(0, 8);
  const high = maskBytes.slice(8, 16);
  const tz = (half: number[]) => {
    const i = half.findIndex((b) => b !== 0);
    return i === -1 ? 64 : i * 8;
  };
  const lowCount = tz(low);
  const highCount = tz(high);
  const lowEmpty = lowCount >> 6; // 1 when the low word held no hit
  const lane = (lowCount >> 3) + ((highCount >> 3) & (lowEmpty ? 0xff : 0));

  // The nibble form: `shrn` folds each 0xFF/0x00 lane to 0xF/0x0, so sixteen lanes become one word.
  const nibbles = maskBytes.map((b) => (b ? "F" : "0")).reverse().join("");

  const cells: Cell[] = block.hit.map((on, i) => ({
    text: on ? "FF" : "00",
    sub: String(i),
    on,
    // The half under the current count is the one being read; the other recedes.
    dim: (op === 1 && i >= 8) || (op === 2 && i < 8),
    marked: op >= 4 && i === block.hitLane
  }));

  const nibbleCells: Cell[] = block.hit.map((on, i) => ({
    text: on ? "F" : "0",
    sub: String(i),
    on
  }));

  const marks: TapeMark[] = [
    { from: 0, to: block.offset, kind: "done" },
    { from: block.offset, to: block.offset + 16, kind: "window" }
  ];
  if (op >= 4 && block.anyHit) {
    marks.push({ from: block.offset + lane, to: block.offset + lane + 1, kind: "cursor" });
  }

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={blocks.length * perBlock}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Instruction"
      />

      <StepNote op={OPS[op].op}>
        Block {which + 1} of {blocks.length} — {OPS[op].note}.
      </StepNote>

      <InputTape
        bytes={trace.bytes}
        marks={marks}
        label="the bytes the mask came from"
        caption={
          op >= 4 && block.anyHit ? (
            <>
              The lane index is only useful as a byte offset, and this is it: block start{" "}
              {block.offset} + lane {lane} = byte <strong>{block.offset + lane}</strong>.
            </>
          ) : (
            <>
              The mask below is one bit of information per byte of this window. The whole function
              exists to turn it back into one of these offsets.
            </>
          )
        }
      />

      <div className="vec-stack">
        <VectorRow
          op="hit"
          note="from the compares"
          cells={cells}
          kind="mask"
          phase={at(0)}
          epoch={which * 8 + op}
        />
        <VectorRow
          op="shrn"
          note="4-bit lanes"
          cells={nibbleCells}
          kind="mask"
          phase={at(3)}
          epoch={which}
        />
      </div>

      <div className="movemask">
        <div className={`mm-branch ${op === 1 || op === 2 ? "now" : op < 1 ? "future" : ""}`}>
          <h5>portable — two words, two counts</h5>
          <p>
            The mask's bytes <em>are</em> 0xFF or 0x00, so reading the register as two 64-bit words
            puts each lane in its own byte and the lane index is the trailing-zero count over eight.
          </p>
          <dl>
            <div className={op < 1 ? "pending" : op === 1 ? "lit" : ""}>
              <dt>low word</dt>
              <dd>
                {op < 1 ? (
                  <span className="pending-value">—</span>
                ) : (
                  <>
                    <code>0x{word(low)}</code> → tzcnt <strong>{lowCount}</strong>
                  </>
                )}
              </dd>
            </div>
            <div className={op < 2 ? "pending" : op === 2 ? "lit" : ""}>
              <dt>high word</dt>
              <dd>
                {op < 2 ? (
                  <span className="pending-value">—</span>
                ) : (
                  <>
                    <code>0x{word(high)}</code> → tzcnt <strong>{highCount}</strong>
                  </>
                )}
              </dd>
            </div>
          </dl>
        </div>

        <div className={`mm-branch ${op === 3 ? "now" : op < 3 ? "future" : ""}`}>
          <h5>arm64 — one narrow, one count</h5>
          <p>
            <code>vshrn_n_u16</code> narrows each 16-bit pair by four, folding every lane to a
            nibble. Swift cannot spell it — the shift is an immediate — so it lives in
            <code> StreamParsingShims</code>.
          </p>
          <dl>
            <div className={op < 3 ? "pending" : op === 3 ? "lit" : ""}>
              <dt>shrn</dt>
              <dd>{op < 3 ? <span className="pending-value">—</span> : <code>0x{nibbles}</code>}</dd>
            </div>
            <div className={op < 3 ? "pending" : op === 3 ? "lit" : ""}>
              <dt>lane</dt>
              <dd>
                {op < 3 ? (
                  <span className="pending-value">—</span>
                ) : (
                  <>
                    tzcnt ÷ 4 = <strong>{block.hitLane}</strong>
                  </>
                )}
              </dd>
            </div>
          </dl>
        </div>
      </div>

      <div className={`mm-arith ${op === 4 ? "now" : op < 4 ? "future" : ""}`}>
        <code>lowEmpty = 0 - (lowCount &gt;&gt; 6)</code>
        <span>{op < 4 ? "—" : lowEmpty ? "= all ones" : "= 0"}</span>
        <code>lane = (lowCount &gt;&gt; 3) + ((highCount &gt;&gt; 3) &amp; lowEmpty)</code>
        <span>
          {op < 4 ? (
            "—"
          ) : (
            <>
              = <strong>{lane}</strong>
            </>
          )}
        </span>
      </div>

      <p className="viz-caption">
        {op < 4 ? (
          <>
            Nothing has been resolved yet — the mask says <em>whether</em> and the counts say{" "}
            <em>where</em>, and the two are still separate values.
          </>
        ) : block.anyHit ? (
          <>
            Lane <strong>{lane}</strong>, so the run ends at byte{" "}
            <strong>{block.offset + lane}</strong>.
          </>
        ) : (
          <>
            No hit: both counts are 64, so the sum is 8 + 8 = <strong>16</strong> — one past the
            block. "Is there a terminator" and "where is it" stay the same value, so the bound check
            <em> is</em> the terminator test and nothing extra is computed to answer it.
          </>
        )}{" "}
        {op >= 4 && lane !== block.hitLane && (
          <strong style={{ color: "var(--critical)" }}>
            This disagrees with the recorded lane {block.hitLane}.
          </strong>
        )}
      </p>

      <p className="viz-note">
        Bit 6 of the low count <em>is</em> "the low word had no hit", so masking the high word's
        contribution by it needs no select. Written as a ternary the intent was a <code>cmov</code>,
        and on arm64 that is what it would be — but LLVM's <code>X86CmovConverterPass</code> turns a
        <code> cmov</code> back into a branch when it judges the condition predictable and the value
        on a critical path, so x86 got two branches and a jump-around instead. The alternative it
        replaced, <code>for lane in 0..&lt;16 where hit[lane]</code>, unrolls into sixteen
        test/branch pairs plus sixteen constant-materialising exit blocks.
      </p>
    </div>
  );
}
