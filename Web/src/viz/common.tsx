import { useEffect, useState } from "react";
import type { CSSProperties, MouseEvent, ReactNode } from "react";
import { cx } from "../lib/cx";
import type { Cell, RowPhase, TapeMark } from "../lib/viz";
import { glyph, hex, tapeKindAt } from "../lib/viz";

// MARK: - The step player

export interface Player {
  index: number;
  count: number;
  playing: boolean;
  play: () => void;
  seek: (index: number) => void;
}

const prefersReducedMotion = () =>
  window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;

/**
 * Step player shared by every visualization: a scrubber, a play/pause, and autoplay that stops at
 * the end rather than looping. Honours `prefers-reduced-motion` by stepping once per press instead
 * of autoplaying.
 *
 * It rewinds whenever `count` or `resetKey` changes — a different case, a different table — and it
 * does so during render rather than in an effect, so the first frame of the new case is its first
 * step rather than the old case's index applied to new data.
 */
export function useSteps(count: number, intervalMs = 1100, resetKey: unknown = null): Player {
  const [index, setIndex] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [shownFor, setShownFor] = useState<[number, unknown]>([count, resetKey]);
  if (shownFor[0] !== count || shownFor[1] !== resetKey) {
    setShownFor([count, resetKey]);
    setIndex(0);
    setPlaying(false);
  }

  useEffect(() => {
    if (!playing) return;
    if (index >= count - 1) {
      setPlaying(false);
      return;
    }
    const timer = window.setTimeout(() => setIndex(index + 1), intervalMs);
    return () => window.clearTimeout(timer);
  }, [playing, index, count, intervalMs]);

  const play = () => {
    if (prefersReducedMotion()) {
      setIndex(Math.min(index + 1, count - 1));
      return;
    }
    if (!playing && index >= count - 1) setIndex(0);
    setPlaying(!playing);
  };

  return { index: Math.min(index, Math.max(count - 1, 0)), count, playing, play, seek: setIndex };
}

export function StepBar({ player, label }: { player: Player; label: string }) {
  const { index, count, playing, play, seek } = player;
  return (
    <div className="viz-controls">
      <button onClick={play} aria-label={playing ? "Pause" : "Play"}>
        {playing ? "❙❙ Pause" : "▶ Play"}
      </button>
      <input
        type="range"
        min={0}
        max={Math.max(count - 1, 0)}
        value={index}
        onChange={(e) => seek(Number(e.target.value))}
        aria-label={label}
        style={{ flex: 1, minWidth: 120 }}
      />
      <span className="mono" style={{ fontSize: 12, color: "var(--text-muted)" }}>
        {index + 1} / {count}
      </span>
    </div>
  );
}

/**
 * The name of the step currently on screen, and what it did.
 *
 * Every stepped visual carries one of these directly under its controls, because "what changed"
 * has to be readable, not only visible.
 */
export function StepNote({ op, children }: { op: string; children: ReactNode }) {
  return (
    <p className="step-note">
      <code>{op}</code>
      <span>{children}</span>
    </p>
  );
}

/** A row of chips choosing which case a visualization steps through. */
export function Choices<T>({
  items,
  selected,
  onSelect,
  label,
  itemKey
}: {
  items: T[];
  selected: number;
  onSelect: (index: number) => void;
  label: (item: T) => ReactNode;
  itemKey: (item: T) => string | number;
}) {
  return (
    <div className="chip-row">
      {items.map((item, i) => (
        <button
          key={itemKey(item)}
          className={cx("chip", i === selected && "active")}
          aria-pressed={i === selected}
          onClick={() => onSelect(i)}
        >
          {label(item)}
        </button>
      ))}
    </div>
  );
}

/** A secondary part of a chip's label, in the muted colour. */
export function ChipNote({ children }: { children: ReactNode }) {
  return <span style={{ color: "var(--text-muted)", marginLeft: 6 }}>{children}</span>;
}

export function Legend({ items }: { items: { color: string; label: string }[] }) {
  return (
    <div className="legend">
      {items.map((item) => (
        <span key={item.label}>
          <i style={{ background: item.color }} />
          {item.label}
        </span>
      ))}
    </div>
  );
}

/** What a trace's own verification says, when it failed: the animation has drifted from the code. */
export function Drifted({ children }: { children: ReactNode }) {
  return (
    <p className="viz-note" style={{ color: "var(--warning)" }}>
      ⚠ {children}
    </p>
  );
}

/** The same, inline at the end of a note that says something else first. */
export function DriftedInline({ children }: { children: ReactNode }) {
  return <strong style={{ color: "var(--warning)" }}> ⚠ {children}</strong>;
}

export function VerifiedNote({ verified }: { verified: boolean }) {
  return verified ? (
    <p className="viz-note">
      Recorded by running the shipped kernel. The stepped-through intermediates were re-derived from
      the same primitives and check out against the real function's answer.
    </p>
  ) : (
    <Drifted>
      This animation disagrees with the shipped kernel — the mirror has drifted. Regenerate with
      <code> ./Web/generate traces</code>.
    </Drifted>
  );
}

// MARK: - The input tape
//
// Every kernel here is reading *the same thing*: bytes out of the caller's buffer. The animations
// used to start at the register, which left the reader with no idea which part of the input a
// given block or call site was looking at. The tape puts the whole sample on screen once and lets
// each step say, in the input's own coordinates, what it is touching: the 16 bytes a vector load
// covers, the single lane a lookup resolves, the bytes already behind the cursor.

/**
 * The sample bytes, with whatever the current step is touching marked.
 *
 * `blockSize` draws a rule every *n* bytes, which is how the 16-byte vector boundary becomes
 * visible without anyone having to count lanes.
 */
export function InputTape({
  bytes,
  marks,
  label,
  blockSize = 16,
  caption
}: {
  bytes: number[];
  marks: TapeMark[];
  label?: string;
  blockSize?: number;
  caption?: ReactNode;
}) {
  return (
    <div className="tape">
      {label && (
        <div className="tape-head">
          <span>{label}</span>
          <span className="tape-count">{bytes.length} bytes</span>
        </div>
      )}
      <div className="tape-bytes">
        {bytes.map((byte, offset) => (
          <i
            key={offset}
            className={cx(
              "tape-byte",
              tapeKindAt(offset, marks),
              blockSize > 0 && offset > 0 && offset % blockSize === 0 && "tick"
            )}
            title={`byte ${offset} · 0x${hex(byte)}`}
          >
            {glyph(byte)}
          </i>
        ))}
      </div>
      {caption && <p className="tape-caption">{caption}</p>}
    </div>
  );
}

// MARK: - SIMD register rendering
//
// Every vector operation in the parser is sixteen lanes wide, and the point of these visuals is
// that the reader should *see* that: one row per register, the operation that produced it named on
// the left, and lanes that line up vertically from one row to the next. A value only ever moves
// down a column, which is what a lane is.
//
// The rows are also a *timeline* (see `phaseOf`): the row a step produces animates its lanes in
// left to right, which is the only motion in the visual and therefore reads as "this is what
// changed".

/**
 * One 16-lane register.
 *
 * `op` is the instruction-ish label; `note` is the register's role. Both sit in a fixed-width
 * gutter so the lanes align across every row of a stack.
 *
 * `epoch` is mixed into the lane keys so that a row whose *contents* change between steps — the
 * accumulator, the SWAR word — remounts and replays its animation; without it React reuses the
 * nodes and the change happens invisibly.
 */
export function VectorRow({
  op,
  note,
  cells,
  kind = "bytes",
  phase = "past",
  epoch = 0
}: {
  op: string;
  note?: string;
  cells: Cell[];
  /** `bytes` for data, `mask` for an all-ones/all-zeros compare result. */
  kind?: "bytes" | "mask";
  phase?: RowPhase;
  epoch?: number;
}) {
  const future = phase === "future";
  return (
    <div className={`vec-row ${phase}`}>
      <div className="vec-gutter">
        <span className="vec-op">{op}</span>
        {note && <span className="vec-note">{note}</span>}
      </div>
      <div className={`vec-lanes ${kind}`}>
        {cells.map((cell, i) => (
          <div
            key={`${phase}-${epoch}-${i}`}
            className={cx(
              "vec-lane",
              future && "ghost",
              !future && cell.on && "on",
              !future && cell.dim && "dim",
              !future && cell.marked && "marked",
              !future && cell.changed && "chg"
            )}
            style={
              {
                "--lane-delay": `${i * 16}ms`,
                ...(!future && cell.on && cell.tone
                  ? { background: cell.tone, borderColor: cell.tone }
                  : {})
              } as CSSProperties
            }
            title={future ? undefined : cell.title}
          >
            <span className="v">{future ? "·" : cell.text}</span>
            {cell.sub !== undefined && <span className="s">{future ? "" : cell.sub}</span>}
          </div>
        ))}
      </div>
    </div>
  );
}

/** The operator between two register rows: `&`, `|`, `^`, `==`. */
export function VectorOp({
  symbol,
  label,
  phase = "past"
}: {
  symbol: string;
  label: string;
  phase?: RowPhase;
}) {
  return (
    <div className={`vec-op-row ${phase}`}>
      <div className="vec-gutter" />
      <div className="vec-op-mark">
        <span className="sym">{symbol}</span>
        <span className="lbl">{label}</span>
      </div>
    </div>
  );
}

/** The lane under the pointer in a `.vec-stack`, by its position in its row. */
export function laneUnder(event: MouseEvent): number | null {
  const lane = (event.target as HTMLElement).closest(".vec-lane");
  const row = lane?.parentElement;
  return lane && row ? Array.prototype.indexOf.call(row.children, lane) : null;
}

/** A bit field rendered low bit first, with the labels the kernel's comment gives them. */
export function Bits({ value, labels }: { value: number; labels: string[] }) {
  return (
    <span className="bits" title={labels.map((l, i) => ((value >> i) & 1 ? `✓ ${l}` : `· ${l}`)).join("\n")}>
      {labels.map((label, i) => (
        <i key={label} className={(value >> i) & 1 ? "on" : ""} aria-label={label} />
      ))}
    </span>
  );
}

/**
 * The 16-entry table itself, with the entry a lane is currently reading highlighted.
 *
 * Drawn as a row of sixteen so it reads as the same shape as the register it indexes into — which
 * it is: `tbl` takes a vector of indices and returns a vector of entries.
 *
 * `touched` is the set of entries the current block reads at all. Lighting those is what turns the
 * table from a legend into a step: a sixteen-lane lookup is sixteen *simultaneous* reads, and the
 * spread of the hits across the table is the reason indexing beats comparing.
 */
export function TableStrip({
  table,
  active,
  touched,
  dim
}: {
  table: { name: string; indexedBy: string; entries: number[]; format: string; bitLabels: string[]; note: string };
  active?: number;
  touched?: Set<number>;
  dim?: boolean;
}) {
  return (
    <div className={cx("table-strip", dim && "dim")}>
      <div className="table-head">
        <strong>{table.name}</strong>
        <code>{table.indexedBy}</code>
      </div>
      <div className="table-cells">
        {table.entries.map((entry, i) => (
          <div
            key={i}
            className={cx(
              "table-cell",
              i === active && "active",
              touched?.has(i) && "touched",
              entry === 0 && "empty"
            )}
          >
            <span className="i">{i.toString(16).toUpperCase()}</span>
            {table.format === "bits" ? (
              <Bits value={entry} labels={table.bitLabels} />
            ) : (
              <span className="e">{hex(entry)}</span>
            )}
          </div>
        ))}
      </div>
      <p className="table-note">{table.note}</p>
    </div>
  );
}

/**
 * The parser's container state: one bit per open container, 1 for an object and 0 for an array,
 * low bit (depth 1) on the left. The bit a step moved pulses; `ringed` marks the depth that
 * matters to the reader — the top of the stack, or the close a skip is waiting for.
 */
export function NestingRegister({
  bits,
  depthBefore,
  depthAfter,
  isObject,
  ringed,
  epoch,
  style,
  children
}: {
  bits: number;
  depthBefore: number;
  depthAfter: number;
  isObject: (bit: number) => boolean;
  ringed: number;
  epoch: number;
  style?: CSSProperties;
  children?: ReactNode;
}) {
  const moved = depthBefore !== depthAfter ? Math.min(depthBefore, depthAfter) : -1;
  return (
    <div className="lanes" style={{ gap: 3, ...style }}>
      {Array.from({ length: bits }, (_, bit) => {
        const live = bit < depthAfter;
        const object = isObject(bit);
        return (
          <div
            key={`${epoch}-${bit}`}
            className={cx(
              "lane",
              live ? (object ? "q" : "b") : "dim",
              bit === ringed && "terminator",
              bit === moved && "chg"
            )}
            style={{ width: 26 }}
            title={live ? `depth ${bit + 1}: ${object ? "object" : "array"}` : `depth ${bit + 1}: unused`}
          >
            <span className="glyph">{live ? (object ? "1" : "0") : "·"}</span>
            <span className="idx">{bit + 1}</span>
          </div>
        );
      })}
      {children}
    </div>
  );
}

/** A labelled key/value pair for the small fact rows these visuals all need. */
export function Facts({ items }: { items: [string, ReactNode][] }) {
  return (
    <dl className="facts">
      {items.map(([term, value]) => (
        <div key={term}>
          <dt>{term}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  );
}
