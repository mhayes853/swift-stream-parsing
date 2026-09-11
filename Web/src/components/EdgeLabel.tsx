import { cx } from "../lib/cx";
import { plain } from "../lib/graph";

/**
 * An arrow's label, drawn over the edges so a crossing line never runs through the text.
 *
 * The halo is a stroke behind the glyphs rather than a rect, so nothing has to measure the text,
 * and the two copies must match exactly — the ordinal's `tspan` is mono and bold, so a plain-string
 * halo measures narrower and a centred pair renders as doubled text.
 */
export function EdgeLabel({
  x,
  y,
  label,
  ordinal,
  lit,
  opacity,
  className
}: {
  x: number;
  y: number;
  label: string;
  ordinal: number | null;
  lit: boolean;
  opacity: number;
  className?: string;
}) {
  return (
    <g opacity={opacity} className={cx("flow-edge-label", className, lit && "lit")}>
      {[true, false].map((halo) => (
        <text key={String(halo)} x={x} y={y} textAnchor="middle" className={halo ? "halo" : undefined}>
          {ordinal !== null && <tspan className="ord">{ordinal} · </tspan>}
          {plain(label)}
        </text>
      ))}
    </g>
  );
}
