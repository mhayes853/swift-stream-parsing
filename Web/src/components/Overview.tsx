import { citations, paragraphs } from "../lib/overview";
import type { DocSection, Overview as OverviewContent, OverviewItem, PipelineNode } from "../types";
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
}

export function How({ overview, sections, nodes }: Part) {
  return (
    <section className="overview">
      <h2 className="panel-rule">How it works</h2>
      <ol className="overview-how">
        {overview.how.map((item, i) => (
          <li key={item.title}>
            <span className="overview-step" aria-hidden="true">
              {i + 1}
            </span>
            <Item item={item} sections={sections} nodes={nodes} />
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

function Item({
  item,
  sections,
  nodes
}: {
  item: OverviewItem;
  sections: Map<string, DocSection>;
  nodes: readonly PipelineNode[];
}) {
  const cites = citations(item, sections, nodes);
  // One element, because a `how` item sits in the second column of its row's grid.
  return (
    <div className="overview-item">
      <h3>{inline(item.title, `t-${item.title}`)}</h3>
      {paragraphs(item).map((p, i) => (
        <p key={i}>{inline(p, `d${i}-${item.title}`)}</p>
      ))}
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
