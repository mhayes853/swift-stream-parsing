import type { ReactNode } from "react";

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
