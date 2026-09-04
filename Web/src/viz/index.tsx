import type { TraceBundle, VizKind } from "../types";
import { CollectionsViz, StreamStringViz, ViewsViz } from "./StorageViz";
import { ContainersViz } from "./ContainersViz";
import { DispositionsViz, SinkCallsViz } from "./SinkViz";
import { EscapeViz } from "./EscapeViz";
import { FieldTableViz, KeyMatchViz } from "./FieldMatchViz";
import { FramesViz, SchemaRoutingViz } from "./FramesViz";
import { MovemaskViz } from "./MovemaskViz";
import { NumberViz } from "./NumberViz";
import { SkipRunViz } from "./SkipRunViz";
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
    case "sinkCalls":
      return <SinkCallsViz trace={traces.sinkCalls} />;
    case "dispositions":
      return <DispositionsViz trace={traces.dispositions} />;
    case "skipRun":
      return <SkipRunViz trace={traces.skipRun} />;
    case "keyMatch":
      return <KeyMatchViz trace={traces.fieldMatch} />;
    case "fieldTable":
      return <FieldTableViz trace={traces.fieldMatch} />;
    case "frames":
      return <FramesViz trace={traces.frames} />;
    case "schemaRouting":
      return <SchemaRoutingViz trace={traces.frames} />;
    case "streamString":
      return <StreamStringViz trace={traces.streamString} />;
    case "collections":
      return <CollectionsViz trace={traces.collections} />;
    case "views":
      return <ViewsViz trace={traces.views} />;
  }
}
