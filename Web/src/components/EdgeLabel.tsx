import { cx } from "../lib/cx";
import { plain } from "../lib/graph";

// The halo must be the same markup as the text: a plain-string halo measures narrower than the
// mono `tspan` and renders as doubled text.
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
