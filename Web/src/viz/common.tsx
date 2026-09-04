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
