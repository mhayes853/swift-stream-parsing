import { KIND_GLYPH, KIND_WORD } from "../lib/graph";
import type { PipelineEdge } from "../types";
import { inline } from "./Markdown";

export function EdgeList({
  edges,
  ordered,
  titleOf,
  single
}: {
  edges: PipelineEdge[];
  ordered: boolean;
  titleOf: (id: string) => string | undefined;
  single: string;
}) {
  const numbered = ordered && edges.length > 1;
  return (
    <>
      <p className="flow-card-rule">
        {edges.length === 1
          ? single
          : numbered
            ? `${edges.length} arrows, in the order the source runs or tests them:`
            : `${edges.length} arrows, in no particular order:`}
      </p>
      <ol className="flow-card-edges">
        {edges.map((edge, i) => (
          <li key={edge.to}>
            <span className={`flow-card-marker kind-${edge.kind}`}>
              {numbered ? i + 1 : KIND_GLYPH[edge.kind]}
            </span>
            <div>
              <p className="flow-card-head">
                <span className="flow-card-label">{inline(edge.label, `l-${i}`)}</span>
                <span className="flow-card-arrow"> → </span>
                <span className="flow-card-target">{titleOf(edge.to) ?? edge.to}</span>
              </p>
              {edge.when && (
                <p>
                  <span className={`flow-card-kind kind-${edge.kind}`}>{KIND_WORD[edge.kind]}</span>
                  {inline(edge.when, `w-${i}`)}
                </p>
              )}
            </div>
          </li>
        ))}
      </ol>
    </>
  );
}
