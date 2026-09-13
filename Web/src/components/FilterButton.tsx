import type { ReactNode } from "react";

/** A toggle in a `.filters` row, with the number of things it would show beside its label. */
export function FilterButton({
  active,
  count,
  onClick,
  children
}: {
  active: boolean;
  count?: number;
  onClick: () => void;
  children: ReactNode;
}) {
  return (
    <button className={active ? "active" : ""} aria-pressed={active} onClick={onClick}>
      {children}
      {count !== undefined && <span className="filter-count">{count}</span>}
    </button>
  );
}
