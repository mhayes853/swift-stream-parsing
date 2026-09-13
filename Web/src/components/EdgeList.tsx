import { KIND_GLYPH, KIND_WORD } from "../lib/graph";
import type { PipelineEdge } from "../types";
import { inline } from "./Markdown";

/**
 * The arrows leaving a node, written out: label, target and the condition each is taken under.
 *
 * The page chart's call card and the panel chart's step card both end in this list, because they
 * are the same claim at two scales. Where the order is real the arrows are numbered; otherwise the
 * marker is the edge kind's glyph, and the kind is written out beside the condition.
 */
export function EdgeList({
  edges,
  ordered,
  titleOf,
  single
}: {
  edges: PipelineEdge[];
  ordered: boolean;
  titleOf: (id: string) => string | undefined;
  /** The rule over a list of one: "Reaches one node:", "Leads to one step:". */
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
