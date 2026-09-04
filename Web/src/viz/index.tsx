import type { TraceBundle, VizKind } from "../types";
import { ContainersViz } from "./ContainersViz";
import { EscapeViz } from "./EscapeViz";
import { MovemaskViz } from "./MovemaskViz";
import { NumberViz } from "./NumberViz";
import { StringRunViz } from "./StringRunViz";
import { TableViz } from "./TableViz";
import { UTF8Viz } from "./UTF8Viz";
import { WhitespaceViz } from "./WhitespaceViz";

export function Visualization({ kind, traces }: { kind: VizKind; traces: TraceBundle | null }) {
  if (!traces) return null;
  switch (kind) {
    case "stringRun":
      return <StringRunViz trace={traces.stringRun} />;
    case "whitespace":
      return <WhitespaceViz trace={traces.whitespace} table={traces.whitespaceTable} />;
    case "containers":
      return <ContainersViz trace={traces.containers} />;
    case "number":
      return <NumberViz cases={traces.number.cases} />;
    case "movemask":
      return <MovemaskViz trace={traces.stringRun} />;
    case "whitespaceTable":
      return <TableViz trace={traces.whitespaceTable} />;
    case "numberTable":
      return <TableViz trace={traces.numberTable} />;
    case "utf8":
      return <UTF8Viz trace={traces.utf8} />;
    case "escapes":
      return <EscapeViz trace={traces.escapes} />;
  }
}
