import { laneID } from "../lib/graph";
import { citations, lanes, paragraphs } from "../lib/overview";
import type {
  DocSection,
  Overview as OverviewContent,
  OverviewItem,
  PipelineNode,
  PipelineStage
} from "../types";
import { useMediaQuery } from "./hooks";
import { inline } from "./Markdown";

export function Lede({ paragraphs: text }: { paragraphs: string[] }) {
  return (
    <>
      {text.map((p, i) => (
        <p key={i} className={i === 0 ? "lede" : undefined}>
          {inline(p, `l${i}`)}
        </p>
      ))}
    </>
  );
}

interface Part {
  overview: OverviewContent;
  sections: Map<string, DocSection>;
  nodes: readonly PipelineNode[];
  stages?: readonly PipelineStage[];
}

export function How({ overview, sections, nodes, stages = [] }: Part) {
  return (
    <section className="overview">
      <h2 className="panel-rule">How it works</h2>
      <ol className="overview-how">
        {overview.how.map((item, i) => (
          <li key={item.title}>
            <span className="overview-step" aria-hidden="true">
              {i + 1}
            </span>
            <Item item={item} sections={sections} nodes={nodes} stages={stages} />
          </li>
        ))}
      </ol>
    </section>
  );
}

// Drawn under the chart: an argument reads better once the shape it is about is on screen.
export function Why({ overview, sections, nodes }: Part) {
  return (
    <section className="overview why">
      <h2 className="panel-rule">Why it is built this way</h2>
      <div className="overview-why">
        {overview.why.map((item) => (
          <article key={item.title}>
            <Item item={item} sections={sections} nodes={nodes} />
          </article>
        ))}
      </div>
    </section>
  );
}

// Measured rather than `scrollIntoView`, so the lane lands below the sticky top bar instead of
// underneath it.
function scrollToLane(stage: string, instant: boolean) {
  const lane = document.getElementById(laneID(stage));
  if (!lane) return;
  const top = lane.getBoundingClientRect().top + window.scrollY - 76;
  window.scrollTo({ top, behavior: instant ? "auto" : "smooth" });
}

function Item({
  item,
  sections,
  nodes,
  stages = []
}: {
  item: OverviewItem;
  sections: Map<string, DocSection>;
  nodes: readonly PipelineNode[];
  stages?: readonly PipelineStage[];
}) {
  const cites = citations(item, sections, nodes);
  const rows = lanes(item, stages);
  const instant = useMediaQuery("(prefers-reduced-motion: reduce)");
  // One element, because a `how` item sits in the second column of its row's grid.
  return (
    <div className="overview-item">
      <h3>{inline(item.title, `t-${item.title}`)}</h3>
      {paragraphs(item).map((p, i) => (
        <p key={i}>{inline(p, `d${i}-${item.title}`)}</p>
      ))}
      {rows.length > 0 && (
        <p className="overview-lanes">
          <span>In the chart</span>
          {rows.map((row) => (
            <button
              key={row.id}
              type="button"
              aria-label={`Scroll the chart to ${row.title}`}
              onClick={() => scrollToLane(row.id, instant)}
            >
              {row.title} ↓
            </button>
          ))}
        </p>
      )}
      {cites.length > 0 && (
        <p className="overview-cites">
          {cites.map((cite) =>
            cite.kind === "node" ? (
              <a key={cite.id} href={cite.href}>
                {cite.label}
              </a>
            ) : (
              <a key={cite.id} href={cite.href} target="_blank" rel="noreferrer">
                {cite.label} ↗
              </a>
            )
          )}
        </p>
      )}
    </div>
  );
}
