import { useCallback, useEffect, useRef, useState } from "react";
import type { CSSProperties, ReactNode } from "react";

/** Printable stand-in for a byte, so a control character still occupies its lane visibly. */
export function glyph(byte: number): string {
  switch (byte) {
    case 0x20: return "␣";
    case 0x09: return "⇥";
    case 0x0a: return "⏎";
    case 0x0d: return "⏎";
    case 0x22: return '"';
    case 0x5c: return "\\";
    default:
      if (byte < 0x20) return "␀";
      if (byte > 0x7e) return "·";
      return String.fromCharCode(byte);
  }
}

/**
 * Step player shared by every visualization: a scrubber, a play/pause, and autoplay that stops at
 * the end rather than looping. Honours `prefers-reduced-motion` by never autoplaying.
 */
export function useSteps(count: number, intervalMs = 1100) {
  const [index, setIndex] = useState(0);
  const [playing, setPlaying] = useState(false);
  const timer = useRef<number | null>(null);

  useEffect(() => {
    setIndex(0);
    setPlaying(false);
  }, [count]);

  useEffect(() => {
    if (!playing) return;
    timer.current = window.setInterval(() => {
      setIndex((i) => {
        if (i + 1 >= count) {
          setPlaying(false);
          return i;
        }
        return i + 1;
      });
    }, intervalMs);
    return () => {
      if (timer.current) window.clearInterval(timer.current);
    };
  }, [playing, count, intervalMs]);

  const play = useCallback(() => {
    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    if (reduced) {
      setIndex((i) => Math.min(i + 1, count - 1));
      return;
    }
    setIndex((i) => (i + 1 >= count ? 0 : i));
    setPlaying((p) => !p);
  }, [count]);

  return { index, setIndex, playing, play, setPlaying };
}

export function StepBar({
  index,
  count,
  playing,
  onPlay,
  onSeek,
  label
}: {
  index: number;
  count: number;
  playing: boolean;
  onPlay: () => void;
  onSeek: (n: number) => void;
  label: string;
}) {
  return (
    <div className="viz-controls">
      <button onClick={onPlay} aria-label={playing ? "Pause" : "Play"}>
        {playing ? "❙❙ Pause" : "▶ Play"}
      </button>
      <input
        type="range"
        min={0}
        max={Math.max(count - 1, 0)}
        value={index}
        onChange={(e) => onSeek(Number(e.target.value))}
        aria-label={label}
        style={{ flex: 1, minWidth: 120 }}
      />
      <span className="mono" style={{ fontSize: 12, color: "var(--text-muted)" }}>
        {index + 1} / {count}
      </span>
    </div>
  );
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

export function VerifiedNote({ verified }: { verified: boolean }) {
  return verified ? (
    <p className="viz-note">
      Recorded by running the shipped kernel. The stepped-through intermediates were re-derived from
      the same primitives and check out against the real function's answer.
    </p>
  ) : (
    <p className="viz-note" style={{ color: "var(--warning)" }}>
      ⚠ This animation disagrees with the shipped kernel — the mirror has drifted. Regenerate with
      <code> ./Web/generate traces</code>.
    </p>
  );
}

// MARK: - The input tape
//
// Every kernel here is reading *the same thing*: bytes out of the caller's buffer. The animations
// used to start at the register, which left the reader with no idea which part of the input a
// given block or call site was looking at. The tape puts the whole sample on screen once and lets
// each step say, in the input's own coordinates, what it is touching: the 16 bytes a vector load
// covers, the single lane a lookup resolves, the bytes already behind the cursor.

export type TapeKind = "done" | "window" | "cursor" | "next";

export interface TapeMark {
  /** Inclusive byte offset. */
  from: number;
  /** Exclusive byte offset. */
  to: number;
  kind: TapeKind;
}

/** Later marks win, so a `cursor` written after a `window` shows through it. */
function tapeClass(offset: number, marks: TapeMark[]): string {
  let out = "";
  for (const mark of marks) {
    if (offset >= mark.from && offset < mark.to) out = mark.kind;
  }
  return out;
}

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
            className={`tape-byte ${tapeClass(offset, marks)} ${
              blockSize && offset % blockSize === 0 && offset > 0 ? "tick" : ""
            }`}
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
// The rows are also a *timeline*. A stack is stepped through, and a row is one of three things at
// any point: not computed yet, computed by this step, or already computed. A future row keeps its
// space and shows nothing, so the stack never reflows; the row a step produces animates its lanes
// in left to right, which is the only motion in the visual and therefore reads as "this is what
// changed".

export type RowPhase = "past" | "now" | "future";

export interface Cell {
  /** The value in this lane. */
  text: string;
  /** Smaller line underneath — the byte a mask came from, a lane index, a glyph. */
  sub?: string;
  /** Set lanes: 0xFF in a mask, a member of the class under test. */
  on?: boolean;
  /** Lanes past the answer, or otherwise not participating. */
  dim?: boolean;
  /** Overrides the set colour, for the three terminator classes. */
  tone?: string;
  /** Ringed: the lane the whole operation resolves to. */
  marked?: boolean;
  /** This lane's value differs from the previous step's — pulsed rather than merely re-rendered. */
  changed?: boolean;
  title?: string;
}

/**
 * One 16-lane register.
 *
 * `op` is the instruction-ish label; `note` is the register's role. Both sit in a fixed-width
 * gutter so the lanes align across every row of a stack.
 *
 * `phase` places the row on the step timeline. `epoch` is mixed into the lane keys so that a row
 * whose *contents* change between steps — the accumulator, the SWAR word — remounts and replays
 * its animation; without it React reuses the nodes and the change happens invisibly.
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
            className={[
              "vec-lane",
              future ? "ghost" : "",
              !future && cell.on ? "on" : "",
              !future && cell.dim ? "dim" : "",
              !future && cell.marked ? "marked" : "",
              !future && cell.changed ? "chg" : ""
            ].join(" ")}
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

/** A splatted constant: the same byte in all sixteen lanes, which is what `vdupq_n_u8` costs. */
export function splat(value: string, count = 16): Cell[] {
  return Array.from({ length: count }, () => ({ text: value, dim: true }));
}

export function hex(byte: number): string {
  return byte.toString(16).toUpperCase().padStart(2, "0");
}

/** Lanes whose value changed against the previous step, so the pulse marks the delta. */
export function diff(now: number[], before: number[] | undefined): boolean[] {
  return now.map((v, i) => before !== undefined && before[i] !== v);
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
  onHover,
  dim
}: {
  table: { name: string; indexedBy: string; entries: number[]; format: string; bitLabels: string[]; note: string };
  active?: number;
  touched?: Set<number>;
  onHover?: (index: number | null) => void;
  dim?: boolean;
}) {
  return (
    <div className={`table-strip ${dim ? "dim" : ""}`}>
      <div className="table-head">
        <strong>{table.name}</strong>
        <code>{table.indexedBy}</code>
      </div>
      <div className="table-cells">
        {table.entries.map((entry, i) => (
          <div
            key={i}
            className={[
              "table-cell",
              i === active ? "active" : "",
              touched?.has(i) ? "touched" : "",
              entry === 0 ? "empty" : ""
            ].join(" ")}
            onMouseEnter={() => onHover?.(i)}
            onMouseLeave={() => onHover?.(null)}
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
