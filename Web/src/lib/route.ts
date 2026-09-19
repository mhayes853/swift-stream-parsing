export const VIEWS = [
  { id: "flow", label: "Parse path" },
  { id: "graveyard", label: "Experiments" },
  { id: "payloads", label: "Payloads" }
] as const;
export type View = (typeof VIEWS)[number]["id"];

export interface Route {
  view: View;
  node: string | null;
}

// `#/flow/<node id>`, `#/graveyard`, `#/payloads`. Anything unrecognised is the parse path.
export function parseRoute(hash: string, nodeIds: ReadonlySet<string>): Route {
  const [view, node] = hash.replace(/^#\/?/, "").split("/").map(decodeURIComponent);
  if (view === "graveyard" || view === "payloads") return { view, node: null };
  return { view: "flow", node: node && nodeIds.has(node) ? node : null };
}

export function formatRoute({ view, node }: Route): string {
  return view === "flow" && node ? `#/flow/${encodeURIComponent(node)}` : `#/${view}`;
}
