import { useEffect, useState } from "react";
import type { CSSProperties, MouseEvent, ReactNode } from "react";
import { cx } from "../lib/cx";
import type { Cell, RowPhase, TapeMark } from "../lib/viz";
import { glyph, hex, tapeKindAt } from "../lib/viz";

export interface Player {
  index: number;
  count: number;
  playing: boolean;
  play: () => void;
  seek: (index: number) => void;
}

const prefersReducedMotion = () =>
  window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;

// Rewinds during render, not in an effect, so a new case never shows the old case's index.
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

export function StepNote({ op, children }: { op: string; children: ReactNode }) {
  return (
    <p className="step-note">
      <code>{op}</code>
      <span>{children}</span>
    </p>
  );
}

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

export function Drifted({ children }: { children: ReactNode }) {
  return (
    <p className="viz-note" style={{ color: "var(--warning)" }}>
      ⚠ {children}
    </p>
  );
}

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

// `epoch` is in the lane keys so a row whose contents change remounts and replays its animation.
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

export function laneUnder(event: MouseEvent): number | null {
  const lane = (event.target as HTMLElement).closest(".vec-lane");
  const row = lane?.parentElement;
  return lane && row ? Array.prototype.indexOf.call(row.children, lane) : null;
}

export function Bits({ value, labels }: { value: number; labels: string[] }) {
  return (
    <span className="bits" title={labels.map((l, i) => ((value >> i) & 1 ? `✓ ${l}` : `· ${l}`)).join("\n")}>
      {labels.map((label, i) => (
        <i key={label} className={(value >> i) & 1 ? "on" : ""} aria-label={label} />
      ))}
    </span>
  );
}

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
