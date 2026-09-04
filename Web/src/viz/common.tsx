import { useCallback, useEffect, useRef, useState } from "react";

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

// MARK: - SIMD register rendering
//
// Every vector operation in the parser is sixteen lanes wide, and the point of these visuals is
// that the reader should *see* that: one row per register, the operation that produced it named on
// the left, and lanes that line up vertically from one row to the next. A value only ever moves
// down a column, which is what a lane is.

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
  title?: string;
}

/**
 * One 16-lane register.
 *
 * `op` is the instruction-ish label; `note` is the register's role. Both sit in a fixed-width
 * gutter so the lanes align across every row of a stack.
 */
export function VectorRow({
  op,
  note,
  cells,
  kind = "bytes"
}: {
  op: string;
  note?: string;
  cells: Cell[];
  /** `bytes` for data, `mask` for an all-ones/all-zeros compare result. */
  kind?: "bytes" | "mask";
}) {
  return (
    <div className="vec-row">
      <div className="vec-gutter">
        <span className="vec-op">{op}</span>
        {note && <span className="vec-note">{note}</span>}
      </div>
      <div className={`vec-lanes ${kind}`}>
        {cells.map((cell, i) => (
          <div
            key={i}
            className={[
              "vec-lane",
              cell.on ? "on" : "",
              cell.dim ? "dim" : "",
              cell.marked ? "marked" : ""
            ].join(" ")}
            style={cell.on && cell.tone ? { background: cell.tone, borderColor: cell.tone } : undefined}
            title={cell.title}
          >
            <span className="v">{cell.text}</span>
            {cell.sub !== undefined && <span className="s">{cell.sub}</span>}
          </div>
        ))}
      </div>
    </div>
  );
}

/** The operator between two register rows: `&`, `|`, `^`, `==`. */
export function VectorOp({ symbol, label }: { symbol: string; label: string }) {
  return (
    <div className="vec-op-row">
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
 */
export function TableStrip({
  table,
  active,
  onHover
}: {
  table: { name: string; indexedBy: string; entries: number[]; format: string; bitLabels: string[]; note: string };
  active?: number;
  onHover?: (index: number | null) => void;
}) {
  return (
    <div className="table-strip">
      <div className="table-head">
        <strong>{table.name}</strong>
        <code>{table.indexedBy}</code>
      </div>
      <div className="table-cells">
        {table.entries.map((entry, i) => (
          <div
            key={i}
            className={`table-cell ${i === active ? "active" : ""} ${entry === 0 ? "empty" : ""}`}
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
