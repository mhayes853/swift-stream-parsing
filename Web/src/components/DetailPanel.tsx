import { useEffect, useState } from "react";
import { loadAssembly, loadSources } from "../data";
import { spanOf } from "../lib/dates";
import {
  byVerdictThenAge,
  declLanguage,
  declWhere,
  listingSummary,
  nodeEvidence,
  repoURL,
  sectionWhere
} from "../lib/evidence";
import type { DocSection, PipelineNode, SourceDecl, TraceBundle } from "../types";
import { Visualization } from "../viz";
import { AlgorithmChart } from "./AlgorithmChart";
import { Recorded, RecordedDetail } from "./dates";
import { Reaches } from "./FlowChart";
import { Code } from "./highlight";
import { useEscape } from "./hooks";
import { Markdown, VerdictChip } from "./Markdown";

type Tab = "explanation" | "experiments" | "source" | "assembly";

/**
 * Everything under one node: its chart and animation, the experiments that settled it, the source
 * and the assembly. Keyed by node id where it is used, so each node opens on its explanation.
 */
export function DetailPanel({
  node,
  sections,
  traces,
  titleOf,
  onClose
}: {
  node: PipelineNode;
  sections: Map<string, DocSection>;
  traces: TraceBundle | null;
  /** Another node's title by id, for the arrows leaving this one. */
  titleOf: (id: string) => string | undefined;
  onClose: () => void;
}) {
  const [tab, setTab] = useState<Tab>("explanation");
  const decls = useSources();
  useEscape(onClose);

  const { experiments, explanations } = nodeEvidence(node, sections);
  const tabs: [Tab, string, number][] = [
    ["explanation", "Explanation", explanations.length],
    ["experiments", "Experiments", experiments.length],
    ["source", "Source", node.evidence.source.length],
    ["assembly", "Assembly", node.evidence.asm.length]
  ];

  return (
    <>
      <div className="scrim" onClick={onClose} />
      <aside className="panel" role="dialog" aria-modal="true" aria-label={node.title}>
        <button className="close" onClick={onClose} aria-label="Close">
          ×
        </button>
        <div className="panel-head">
          <h2>{node.title}</h2>
          <div className="sub">{node.kicker}</div>
          <div className="panel-tabs" role="tablist">
            {tabs.map(([id, label, count]) => (
              <button key={id} role="tab" aria-selected={tab === id} onClick={() => setTab(id)}>
                {label}
                <span className="count">{count}</span>
              </button>
            ))}
          </div>
        </div>
        <div className="panel-body">
          {tab === "explanation" && (
            <Explanation
              node={node}
              sections={explanations}
              traces={traces}
              decls={decls.value}
              titleOf={titleOf}
            />
          )}
          {tab === "experiments" && <Experiments sections={experiments} />}
          {tab === "source" && <Source keys={node.evidence.source} sources={decls} />}
          {tab === "assembly" && <Assembly symbols={node.evidence.asm} />}
        </div>
      </aside>
    </>
  );
}

interface Sources {
  value: Record<string, SourceDecl[]> | null;
  error: string | null;
}

/** The declaration bundle: the Source tab lists it, and the algorithm chart resolves a step's file
 *  and line out of it. Loaded once and shared (see `loadSources`). */
function useSources(): Sources {
  const [sources, setSources] = useState<Sources>({ value: null, error: null });
  useEffect(() => {
    loadSources().then(
      (bundle) => setSources({ value: bundle.sources, error: null }),
      (e) => setSources({ value: null, error: String(e) })
    );
  }, []);
  return sources;
}

function Explanation({
  node,
  sections,
  traces,
  decls,
  titleOf
}: {
  node: PipelineNode;
  sections: DocSection[];
  traces: TraceBundle | null;
  decls: Record<string, SourceDecl[]> | null;
  titleOf: (id: string) => string | undefined;
}) {
  return (
    <>
      {/* The chart before the animation: the shape of the thing, then one run through it. */}
      <AlgorithmChart node={node} decls={decls} />
      {node.viz && (
        <div style={{ marginBottom: 20 }}>
          <Visualization kind={node.viz} traces={traces} />
        </div>
      )}
      <div className="md">
        {node.prose.map((p, i) => (
          <p key={i} className={i === 0 ? "lede" : undefined}>
            {p}
          </p>
        ))}
      </div>
      {/* The page chart's call card, for a screen that cannot hover to open it. */}
      {node.next.length > 0 && (
        <div className="reaches touch-only">
          <h3 className="panel-rule">Where it goes next</h3>
          <Reaches node={node} titleOf={titleOf} />
        </div>
      )}
      {sections.length > 0 && (
        <>
          <h3 className="panel-rule">From the architecture log</h3>
          {sections.map((section) => (
            <SectionCard key={section.path} section={section} />
          ))}
        </>
      )}
    </>
  );
}

function Experiments({ sections }: { sections: DocSection[] }) {
  if (sections.length === 0) {
    return <p className="empty">No experiment with a recorded verdict is attached to this step.</p>;
  }
  const sorted = byVerdictThenAge(sections);
  const tried = spanOf(sorted.map((s) => s.history?.recorded));
  return (
    <>
      <p className="callout">
        Measured on arm64 (M1 Pro), each against its own control. Rejected results are listed first,
        oldest first within each verdict.
        {tried && ` Tried between ${tried}.`}
      </p>
      {sorted.map((section) => (
        <SectionCard key={section.path} section={section} defaultOpen={sorted.length <= 2} />
      ))}
    </>
  );
}

function SectionCard({ section, defaultOpen = false }: { section: DocSection; defaultOpen?: boolean }) {
  return (
    <details className="evidence-item" open={defaultOpen}>
      <summary>
        <span className="summary-head">
          <span style={{ flex: 1 }}>{section.title}</span>
          <Recorded history={section.history} />
          <VerdictChip verdict={section.verdict} />
        </span>
      </summary>
      <div className="summary-line">
        <span className="where">{sectionWhere(section)}</span>
      </div>
      <div className="evidence-body">
        <Markdown>{section.markdown}</Markdown>
        {section.history && (
          <p className="provenance">
            <RecordedDetail history={section.history} />
          </p>
        )}
        <RepoLink href={repoURL("NEW_ARCHITECTURE.md", section.line)} />
      </div>
    </details>
  );
}

function RepoLink({ href }: { href: string }) {
  return (
    <a href={href} target="_blank" rel="noreferrer" style={{ fontSize: 12.5 }}>
      Open in the repository ↗
    </a>
  );
}

function Source({ keys, sources }: { keys: string[]; sources: Sources }) {
  if (sources.error) return <p className="empty">{sources.error}</p>;
  if (!sources.value) return <p className="empty">Loading declarations…</p>;
  if (keys.length === 0) return <p className="empty">No source attached to this step.</p>;
  const decls = sources.value;

  return (
    <>
      {keys.flatMap((key) => {
        const matches = decls[key] ?? [];
        return matches.map((decl, i) => (
          <details className="evidence-item" key={`${key}-${i}`} open={matches.length === 1 && keys.length <= 2}>
            <summary>
              <span className="summary-head">
                <span className="summary-symbol">
                  {decl.qualifiedName}
                  {matches.length > 1 ? ` (${i + 1}/${matches.length})` : ""}
                </span>
                <span className="kicker">{decl.kind}</span>
              </span>
            </summary>
            <div className="summary-line">
              <span className="where">{declWhere(decl)}</span>
            </div>
            <div className="evidence-body">
              {decl.comment && (
                <>
                  <h4 className="source-why">Why, from the source</h4>
                  <Markdown>{decl.comment}</Markdown>
                </>
              )}
              <Code language={declLanguage(decl)}>{decl.code}</Code>
              {decl.members.length > 0 && (
                <p style={{ fontSize: 12.5, color: "var(--text-muted)" }}>
                  Body elided. {decl.members.length} members: <code>{decl.members.join(", ")}</code>
                </p>
              )}
              <RepoLink href={repoURL(decl.file, decl.startLine, decl.endLine)} />
            </div>
          </details>
        ));
      })}
    </>
  );
}

function Assembly({ symbols }: { symbols: string[] }) {
  const [listings, setListings] = useState<Record<string, string>>({});

  useEffect(() => {
    for (const symbol of symbols) {
      loadAssembly(symbol).then(
        (text) => setListings((prev) => ({ ...prev, [symbol]: text })),
        (e) => setListings((prev) => ({ ...prev, [symbol]: `; ${e}` }))
      );
    }
  }, [symbols]);

  if (symbols.length === 0) {
    return (
      <p className="empty">
        No assembly pinned for this step. Most of the hot kernels are <code>@inline(__always)</code>{" "}
        and have no standalone symbol — their instructions live inside whichever caller the optimizer
        folded them into.
      </p>
    );
  }

  return (
    <>
      <p className="callout">
        From the release benchmark binary via <code>llvm-objdump</code>: that is the build where a
        concrete sink specializes the generics. Instruction count is not the metric; the log has
        several results where fewer instructions measured slower.
      </p>
      {symbols.map((symbol) => (
        <details className="evidence-item" key={symbol}>
          <summary>
            <span className="summary-head">
              <span className="summary-symbol">{symbol}</span>
              <span className="kicker">{listingSummary(listings[symbol]) ?? "…"}</span>
            </span>
          </summary>
          <div className="evidence-body">
            <Code language="asm" style={{ maxHeight: 420 }}>
              {listings[symbol] ?? "Loading…"}
            </Code>
          </div>
        </details>
      ))}
    </>
  );
}
