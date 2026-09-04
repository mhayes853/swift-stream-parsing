import type { TraceBundle, VizKind } from "../types";
import { ContainersViz } from "./ContainersViz";
import { NumberViz } from "./NumberViz";
import { StringRunViz } from "./StringRunViz";
import { WhitespaceViz } from "./WhitespaceViz";

export function Visualization({ kind, traces }: { kind: VizKind; traces: TraceBundle | null }) {
  if (!traces) return null;
  switch (kind) {
    case "stringRun":
      return <StringRunViz trace={traces.stringRun} />;
    case "whitespace":
      return <WhitespaceViz trace={traces.whitespace} />;
    case "containers":
      return <ContainersViz trace={traces.containers} />;
    case "number":
      return <NumberViz cases={traces.number.cases} />;
  }
}
