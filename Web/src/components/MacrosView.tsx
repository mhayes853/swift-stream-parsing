import { useMemo, useState } from "react";
import { classifyExpansion, decodeWordMatches, regionBlocks, regionTally, type RegionId } from "../lib/macros";
import { glyph, hex } from "../lib/viz";
import type { LibraryBundle, MacroRegion, MacrosContent } from "../types";
import { Choices } from "../viz/common";
import { AlgorithmChart } from "./AlgorithmChart";
import { Code } from "./highlight";
import { useSources } from "./hooks";
import { Markdown, inline } from "./Markdown";

/** A guide citation (`guide:section-path`) opened in place. */
function GuideSection({ citation, library }: { citation: string; library: LibraryBundle }) {
  const [guide, path] = [citation.slice(0, citation.indexOf(":")), citation.slice(citation.indexOf(":") + 1)];
  const doc = library.guides[guide];
  const section = doc?.sections.find((s) => s.path === path);
  if (!doc || !section) return null;
  return (
    <details className="evidence-item">
      <summary>
        <span className="summary-head">
          <span style={{ flex: 1 }}>{section.title}</span>
          <span className="where">{doc.path.split("/").at(-1)}</span>
        </span>
      </summary>
      <div className="evidence-body">
        <Markdown>{section.markdown}</Markdown>
      </div>
    </details>
  );
}

function WordMatches({ expansion }: { expansion: string }) {
  const matches = useMemo(() => decodeWordMatches(expansion), [expansion]);
  if (matches.length === 0) return null;
  return (
    <section className="word-matches">
      <h3>What the matcher compares</h3>
      <p className="viz-caption">
        Each <code>case</code> in the generated switch is a key, read as eight-byte little-endian words. The
        literal's lowest byte is the key's first, so <code>0x…656D_616E</code> is <code>n a m e</code> read right
        to left. The generator computed these at compile time; decoded here from the expansion.
      </p>
      {matches.map((match) => (
        <div key={match.line} className="word-match">
          <div className="word-key">
            <code>"{match.key}"</code>
            <span className="where">
              {match.count} {match.count === 1 ? "byte" : "bytes"} · line {match.line}
            </span>
          </div>
          {match.words.map((word) => (
            <div key={word.offset} className="word-row">
              <code className="word-literal">{word.literal}</code>
              <div className="word-lanes" aria-label={`bytes ${word.offset} to ${word.offset + 7}`}>
                {word.bytes.map((byte, lane) => {
                  const at = word.offset + lane;
                  const pad = at >= match.count;
                  return (
                    <i key={lane} className={pad ? "pad" : undefined} title={`byte ${at} · 0x${hex(byte)}`}>
                      <b>{pad ? "·" : glyph(byte)}</b>
                      <small>{hex(byte)}</small>
                    </i>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      ))}
    </section>
  );
}

function ExpansionExplorer({
  content,
  library,
  titleOf,
  onNode
}: {
  content: MacrosContent;
  library: LibraryBundle;
  titleOf: (id: string) => string | undefined;
  onNode: (id: string) => void;
}) {
  const [selected, setSelected] = useState(0);
  const [focus, setFocus] = useState<RegionId | null>(null);
  const example = content.examples[selected];
  const snapshot = library.snapshots[example.test];
  const expansion = snapshot?.expansion ?? "";
  const lines = useMemo(() => classifyExpansion(expansion), [expansion]);
  const blocks = useMemo(() => regionBlocks(lines), [lines]);
  const tally = useMemo(() => regionTally(lines), [lines]);
  const byId = useMemo(() => new Map(content.regions.map((r) => [r.id, r])), [content.regions]);
  const stepTitle = (id: string) => content.chart.steps.find((s) => s.id === id)?.title ?? id;
  const focused: MacroRegion | undefined = focus ? byId.get(focus) : undefined;

  return (
    <section className="expansion-explorer">
      <Choices
        items={content.examples}
        selected={selected}
        onSelect={(i) => {
          setSelected(i);
          setFocus(null);
        }}
        label={(e) => e.title}
        itemKey={(e) => e.test}
      />
      <p className="viz-caption">
        {inline(example.detail, "ex")} From the snapshot test{" "}
        <code>{example.test.slice(example.test.indexOf(":") + 1)}</code>, which asserts this expansion line for line.
      </p>

      <div className="region-legend" role="group" aria-label="Generated regions">
        {tally.map(({ region, lines: count }) => {
          const info = byId.get(region);
          return (
            <button
              key={region}
              aria-pressed={focus === region}
              className={`region-chip r-${region}`}
              onClick={() => setFocus(focus === region ? null : region)}
            >
              {info?.title ?? region} <span>{count}</span>
            </button>
          );
        })}
      </div>
      {focused && (
        <p className="region-detail">
          <strong>{focused.title}.</strong> {inline(focused.detail, "rd")} Emitted by{" "}
          <em>{stepTitle(focused.step)}</em>
          {focused.node && (
            <>
              ; read at run time by{" "}
              <button className="linky" onClick={() => onNode(focused.node!)}>
                {titleOf(focused.node) ?? focused.node}
              </button>
            </>
          )}
          .
        </p>
      )}

      <div className="expansion-panes">
        <div className="expansion-input">
          <h4>What the macro was applied to</h4>
          <Code language="swift">{snapshot?.input ?? ""}</Code>
        </div>
        <div className="expansion-output">
          <h4>What it expands to · {lines.length} lines</h4>
          <div className="expansion-blocks">
            {blocks.map((block) => {
              const info = byId.get(block.region);
              const dim = focus !== null && focus !== block.region;
              return (
                <div
                  key={block.start}
                  className={`expansion-block r-${block.region}${dim ? " dim" : ""}${focus === block.region ? " lit" : ""}`}
                >
                  <button
                    className="expansion-tag"
                    onClick={() => setFocus(focus === block.region ? null : block.region)}
                    title={info?.detail}
                  >
                    {info?.title ?? block.region}
                  </button>
                  <Code language="swift">{block.lines.join("\n")}</Code>
                </div>
              );
            })}
          </div>
        </div>
      </div>

      <WordMatches expansion={expansion} />
    </section>
  );
}

export function MacrosView({
  content,
  library,
  error,
  titleOf,
  onNode
}: {
  content: MacrosContent;
  library: LibraryBundle | null;
  error: string | null;
  titleOf: (id: string) => string | undefined;
  onNode: (id: string) => void;
}) {
  const sources = useSources();

  return (
    <section className="library-view">
      <h2 className="view-title">Macros</h2>
      {content.lede.map((p, i) => (
        <p key={i} className="section-lead">
          {inline(p, `l${i}`)}
        </p>
      ))}

      <h2 className="panel-rule">Why the macro support library exists</h2>
      <div className="overview-why">
        {content.why.map((item) => (
          <article key={item.title}>
            <h3>{item.title}</h3>
            {item.detail.map((p, i) => (
              <p key={i}>{inline(p, `${item.title}${i}`)}</p>
            ))}
            {library && item.guide.map((g) => <GuideSection key={g} citation={g} library={library} />)}
            <p className="why-sources">
              {item.source.map((s) => (
                <code key={s}>{s}</code>
              ))}
            </p>
          </article>
        ))}
      </div>

      <h2 className="panel-rule">How a Partial is generated</h2>
      {content.chart.prose.map((p, i) => (
        <p key={i} className="section-lead">
          {inline(p, `c${i}`)}
        </p>
      ))}
      <AlgorithmChart node={content.chart} decls={sources.value} heading={content.chart.title} />

      <h2 className="panel-rule">An expansion, region by region</h2>
      <p className="section-lead">
        Every line of an expansion below is assigned to the step that wrote it. Select a region to pick its lines out
        of the expansion and see what reads them at run time.
      </p>
      {error && <p className="callout warn">Could not load the expansions: {error}</p>}
      {!library && !error && <p className="empty">Loading the expansions…</p>}
      {library && <ExpansionExplorer content={content} library={library} titleOf={titleOf} onNode={onNode} />}
    </section>
  );
}
