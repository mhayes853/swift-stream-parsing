import type { StringRunTrace } from "../types";
import { glyph, Legend, StepBar, useSteps, VerifiedNote } from "./common";

/**
 * `streamStringRun`, block by block.
 *
 * Each step is one 16-byte vector: three compares (quote, backslash, control floor) resolved in
 * parallel, ORed into one mask, and the first set lane taken as the run's end. The three classes
 * use categorical slots 1-3, and every lane also carries its own glyph and index, which is the
 * secondary encoding the light-mode contrast warning on slot 3 obliges.
 */
export function StringRunViz({ trace }: { trace: StringRunTrace }) {
  const steps = trace.blocks.length;
  const { index, setIndex, playing, play } = useSteps(steps, 1400);
  const block = trace.blocks[index];

  if (!block) return null;

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

      <div style={{ fontSize: 12, color: "var(--text-muted)", fontFamily: "var(--font-mono)" }}>
        block at byte {block.offset} · <span style={{ color: "var(--text-secondary)" }}>{trace.sample}</span>
      </div>

      <div className="lanes">
        {block.bytes.map((byte, lane) => {
          const terminator = block.anyHit && lane === block.hitLane;
          const past = block.anyHit && lane > block.hitLane;
          const cls = block.isQuote[lane]
            ? "q"
            : block.isBackslash[lane]
              ? "b"
              : block.isControl[lane]
                ? "c"
                : "";
          return (
            <div
              key={lane}
              className={`lane ${cls} ${past ? "dim" : ""} ${terminator ? "terminator" : ""}`}
              title={`lane ${lane}: 0x${byte.toString(16).padStart(2, "0")}`}
            >
              <span className="glyph">{glyph(byte)}</span>
              <span className="idx">{lane}</span>
            </div>
          );
        })}
      </div>

      <Legend
        items={[
          { color: "var(--series-1)", label: '" quote' },
          { color: "var(--series-2)", label: "\\ backslash" },
          { color: "var(--series-3)", label: "< 0x20 control" }
        ]}
      />

      <p className="viz-caption">
        {block.anyHit ? (
          <>
            The OR of the three compares is non-zero, so the run ends inside this block. The first
            set lane is <strong>{block.hitLane}</strong> — found from the mask itself, not by walking
            lanes — putting the run's end at byte{" "}
            <strong>{block.offset + block.hitLane}</strong>. Bytes past it are masked out before the
            non-ASCII question is asked, which is what makes that answer exact rather than
            conservative.
          </>
        ) : (
          <>
            No lane matches any of the three terminators, so all sixteen bytes are string content.
            They are ORed into the running <code>scanned</code> accumulator — carrying the high-bit
            observation forward for free — and the scan advances a full block.
            {block.nonASCIIAfter ? " Something non-ASCII has been seen so far." : " Still pure ASCII."}
          </>
        )}
      </p>

      <p className="viz-note">
        Result: end {trace.end}, {trace.containsNonASCII ? "contains non-ASCII" : "ASCII only"}.
      </p>
      <VerifiedNote verified={trace.verified} />
    </div>
  );
}
