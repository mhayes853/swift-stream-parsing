import { useState } from "react";
import type {
  SkipBlock,
  SkipBlockTrace,
  StructuralBlock,
  StructuralBlockTrace
} from "../types";
import type { TapeMark } from "../lib/viz";
import {
  glyph,
  skipBlockTimeline,
  structuralBlockTimeline
} from "../lib/viz";
import {
  Choices,
  DriftedInline,
  Facts,
  InputTape,
  StepBar,
  StepNote,
  useSteps
} from "./common";

function MaskStrip({
  label,
  bits,
  original,
  bytes,
  offset,
  cursor,
  epoch
}: {
  label: string;
  bits: boolean[];
  original?: boolean[];
  bytes: number[];
  offset: number;
  cursor?: number;
  epoch: number;
}) {
  return (
    <div className="block-mask-row">
      <div className="block-mask-label">
        <code>{label}</code>
        <span>{bits.filter(Boolean).length} set</span>
      </div>
      <div className="block-mask">
        {bits.map((on, lane) => {
          const cleared = original?.[lane] && !on;
          const current = cursor === offset + lane;
          return (
            <i
              key={`${epoch}-${lane}`}
              className={`${on ? "on" : ""} ${cleared ? "cleared" : ""} ${current ? "current" : ""}`}
              title={`byte ${offset + lane} · ${glyph(bytes[lane] ?? 0)} · ${on ? "set" : "clear"}`}
            >
              {on ? "1" : "·"}
            </i>
          );
        })}
      </div>
    </div>
  );
}

function StrikeMeter({ before, after }: { before: number; after: number }) {
  return (
    <div className="strike-meter" aria-label={`${after} of 4 consecutive strikes`}>
      <span>consecutive strikes</span>
      <div>
        {Array.from({ length: 4 }, (_, i) => (
          <i key={i} className={i < after ? (i >= before ? "new" : "on") : ""} />
        ))}
      </div>
      <strong>{after}/4</strong>
    </div>
  );
}

function structuralNote(step: ReturnType<typeof structuralBlockTimeline>[number], block: StructuralBlock) {
  const visit = step.visit === undefined ? undefined : block.visits[step.visit];
  switch (step.op) {
    case "classify":
      return <>Four 16-byte loads produce <code>starts</code>, <code>quote</code> and <code>backslash</code> for bytes {block.offset}–{block.offset + 63}.</>;
    case "gate":
      return block.givesUp ? (
        <>This is the fourth consecutive block with no useful whitespace. The classifier has paid; the walk deliberately does not visit its mask.</>
      ) : (
        <>The block has {block.noOuterWhitespace ? "no whitespace outside strings" : "whitespace to skip"} and {block.startCount} start candidates, so the strike count becomes {block.strikeAfter}.</>
      );
    case "visit":
      return visit?.reanchors ? (
        <><code>trailingZeroBitCount</code> lands on byte {visit.offset}. The {visit.kind} finishes at {visit.next}; because that is beyond this grid, the next grid begins there.</>
      ) : (
        <><code>trailingZeroBitCount</code> lands on byte {visit?.offset}. The {visit?.kind} consumes through {visit?.next}; every candidate inside that extent disappears from <code>starts</code>.</>
      );
    case "give up":
      return <>The parser stores the gate verdict and returns byte {block.offset} complemented. The dispatcher re-enters the unchanged scalar copy once, then never asks the block walk again for this parse.</>;
    case "advance": {
      const last = block.visits.at(-1);
      return last?.reanchors && last.next !== block.offset + 64 ? (
        <>The grid moves from {block.offset} to {last.next}, not to {block.offset + 64}. The bytes inside the long token are not classified again.</>
      ) : last?.reanchors ? (
        <>The token ends exactly at this grid's edge, so re-anchoring and the ordinary 64-byte advance both resume at byte {last.next}.</>
      ) : (
        <>The mask is exhausted. Everything left in the block is whitespace, so the next zero-carry grid starts at byte {block.offset + 64}.</>
      );
    }
  }
}

export function StructuralBlockViz({ trace }: { trace: StructuralBlockTrace }) {
  const [selected, setSelected] = useState(0);
  const current = trace.cases[selected];
  if (!current) return null;
  const timeline = structuralBlockTimeline(current);
  const player = useSteps(timeline.length, 720, selected);
  const step = timeline[player.index];
  const block = current.blocks[step.block];
  const marks: TapeMark[] = [
    { from: 0, to: block.offset, kind: "done" },
    { from: block.offset, to: Math.min(block.offset + 64, current.bytes.length), kind: "window" }
  ];
  if (step.cursor !== undefined) marks.push({ from: step.cursor, to: step.cursor + 1, kind: "cursor" });
  if (step.next < current.bytes.length) marks.push({ from: step.next, to: step.next + 1, kind: "next" });

  return (
    <div className="viz block-walk-viz">
      <Choices
        items={trace.cases}
        selected={selected}
        onSelect={setSelected}
        label={(item) => item.name}
        itemKey={(item) => item.name}
      />
      <p className="viz-caption block-purpose">{current.purpose}</p>
      <StepBar player={player} label="Block walk step" />
      <StepNote op={step.op}>{structuralNote(step, block)}</StepNote>

      <InputTape
        bytes={current.bytes}
        marks={marks}
        blockSize={16}
        label="the structural run"
        caption={<>The blue window is the current moving 64-byte grid. The filled byte is the next token start; the outlined byte is where the cursor or the next grid resumes.</>}
      />

      <Facts
        items={[
          ["grid p", <code>{block.offset}</code>],
          ["starts", <><strong>{block.startCount}</strong> / 64</>],
          ["outer whitespace", block.noOuterWhitespace ? "none" : "present"],
          ["non-ASCII", block.nonASCII ? "present" : "none"]
        ]}
      />
      <StrikeMeter before={block.strikeBefore} after={block.strikeAfter} />

      <div className="block-masks">
        <MaskStrip
          label="starts"
          bits={step.mask}
          original={block.starts}
          bytes={block.bytes}
          offset={block.offset}
          cursor={step.cursor}
          epoch={player.index}
        />
        <MaskStrip label="quote" bits={block.quotes} bytes={block.bytes} offset={block.offset} epoch={step.block} />
        <MaskStrip label="backslash" bits={block.backslashes} bytes={block.bytes} offset={block.offset} epoch={step.block} />
      </div>

      <p className="viz-note">
        The masks above are returned by <code>stream_parsing_classify_structural_block</code>.
        The mirrored cursor and the shipped walk both stop at byte {current.end}, and block-on and
        block-off full parses emit the same event stream.
        {!current.verified && <DriftedInline>The block trace disagrees with the shipped parser.</DriftedInline>}
      </p>
    </div>
  );
}

function skipNote(
  step: ReturnType<typeof skipBlockTimeline>[number],
  block: SkipBlock
) {
  const visit = step.visit === undefined ? undefined : block.visits[step.visit];
  switch (step.op) {
    case "classify":
      return <>The classifier keeps only <code>{"{ [ } ]"}</code> outside strings. This block contains {block.brackets.filter(Boolean).length} bracket bits to visit.</>;
    case "visit":
      return <>The next bracket is byte {visit?.offset}: <code>{glyph(visit?.byte ?? 0)}</code>. Depth moves {visit?.depthBefore} → {visit?.depthAfter}; every byte before the next set bit is skipped.</>;
    case "carry":
      return <>At byte {block.offset + 64}, quote parity is {block.inStringAfter ? "inside a string" : "outside strings"} and the odd-backslash carry is {block.endsOddAfter ? "set" : "clear"}. That state names the scalar handoff exactly.</>;
  }
}

export function SkipBlockViz({ trace }: { trace: SkipBlockTrace }) {
  const timeline = skipBlockTimeline(trace);
  const player = useSteps(timeline.length, 780);
  const step = timeline[player.index];
  const block = trace.blocks[step.block];
  if (!step || !block) return null;
  const visit = step.visit === undefined ? undefined : block.visits[step.visit];
  const marks: TapeMark[] = [
    { from: trace.from, to: block.offset, kind: "done" },
    { from: block.offset, to: Math.min(block.offset + 64, trace.bytes.length), kind: "window" }
  ];
  if (step.cursor !== undefined) marks.push({ from: step.cursor, to: step.cursor + 1, kind: "cursor" });
  if (step.next < trace.bytes.length) marks.push({ from: step.next, to: step.next + 1, kind: "next" });

  return (
    <div className="viz block-walk-viz">
      <StepBar player={player} label="Skip block step" />
      <StepNote op={step.op}>{skipNote(step, block)}</StepNote>
      <InputTape
        bytes={trace.bytes}
        marks={marks}
        blockSize={16}
        label="the skipped subtree"
        caption={<>Bracket glyphs inside quoted text remain visible in the input, but only the bracket mask below drives the walk.</>}
      />
      <Facts
        items={[
          ["block", <code>{block.offset}…{block.offset + 63}</code>],
          ["depth", <><strong>{visit?.depthBefore ?? block.depthBefore}</strong> → <strong>{visit?.depthAfter ?? block.depthAfter}</strong></>],
          ["string carry", <>{block.inStringBefore ? "in" : "out"} → {block.inStringAfter ? "in" : "out"}</>],
          ["odd \\ carry", <>{block.endsOddBefore ? "1" : "0"} → {block.endsOddAfter ? "1" : "0"}</>]
        ]}
      />
      <div className="block-masks">
        <MaskStrip
          label="brackets"
          bits={step.mask}
          original={block.brackets}
          bytes={block.bytes}
          offset={block.offset}
          cursor={step.cursor}
          epoch={player.index}
        />
      </div>
      <p className="viz-caption">
        Strings, numbers, literals, whitespace and separators never enter the per-byte loop. Only
        these {block.brackets.filter(Boolean).length} bracket bits update <code>depth</code> and the
        container word; UTF-8 remains validated over the skipped bytes.
      </p>
      <p className="viz-note">
        The mirrored block handoff and <code>consumeSkipBlocks</code> both stop at byte {trace.end}
        in state <code>{trace.state}</code>.
        {!trace.verified && <DriftedInline>The skip-block trace disagrees with the shipped parser.</DriftedInline>}
      </p>
    </div>
  );
}
