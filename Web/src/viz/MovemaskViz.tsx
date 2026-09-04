import type { StringRunTrace } from "../types";
import type { Cell } from "./common";
import { StepBar, useSteps, VectorRow } from "./common";

/**
 * `streamFirstHitLane` — getting a lane index out of a vector.
 *
 * This is the step every first-hit problem in the scanners runs into: the compare has already
 * answered "which lanes", in a vector register, and the scalar code needs "which is the first",
 * in a general register. The portable spelling reads the mask's own storage as two 64-bit words
 * and counts trailing zeros; the arm64 spelling narrows each lane to a nibble with `shrn` and
 * counts once. Both are shown because both ship.
 *
 * The arithmetic at the bottom is the branchless combination, and it is the point of the whole
 * function: a terminator's lane is unpredictable by nature, so there is nothing here to predict.
 */
export function MovemaskViz({ trace }: { trace: StringRunTrace }) {
  const blocks = trace.blocks;
  const { index, setIndex, playing, play } = useSteps(blocks.length, 2000);
  const block = blocks[index];
  if (!block) return null;

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
    marked: i === block.hitLane
  }));

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={blocks.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Block"
      />

      <div className="vec-stack">
        <VectorRow op="hit" note="from the compares" cells={cells} kind="mask" />
      </div>

      <div className="movemask">
        <div className="mm-branch">
          <h5>portable — two words, two counts</h5>
          <p>
            The mask's bytes <em>are</em> 0xFF or 0x00, so reading the register as two 64-bit words
            puts each lane in its own byte and the lane index is the trailing-zero count over eight.
          </p>
          <dl>
            <div>
              <dt>low word</dt>
              <dd>
                <code>0x{word(low)}</code> → tzcnt <strong>{lowCount}</strong>
              </dd>
            </div>
            <div>
              <dt>high word</dt>
              <dd>
                <code>0x{word(high)}</code> → tzcnt <strong>{highCount}</strong>
              </dd>
            </div>
          </dl>
        </div>

        <div className="mm-branch">
          <h5>arm64 — one narrow, one count</h5>
          <p>
            <code>vshrn_n_u16</code> narrows each 16-bit pair by four, folding every lane to a
            nibble. Swift cannot spell it — the shift is an immediate — so it lives in
            <code> StreamParsingShims</code>.
          </p>
          <dl>
            <div>
              <dt>shrn</dt>
              <dd>
                <code>0x{nibbles}</code>
              </dd>
            </div>
            <div>
              <dt>lane</dt>
              <dd>
                tzcnt ÷ 4 = <strong>{block.hitLane}</strong>
              </dd>
            </div>
          </dl>
        </div>
      </div>

      <div className="mm-arith">
        <code>lowEmpty = 0 - (lowCount &gt;&gt; 6)</code>
        <span>= {lowEmpty ? "all ones" : "0"}</span>
        <code>lane = (lowCount &gt;&gt; 3) + ((highCount &gt;&gt; 3) &amp; lowEmpty)</code>
        <span>
          = <strong>{lane}</strong>
        </span>
      </div>

      <p className="viz-caption">
        {block.anyHit ? (
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
        {lane === block.hitLane ? (
          ""
        ) : (
          <strong style={{ color: "var(--critical)" }}>
            {" "}
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
