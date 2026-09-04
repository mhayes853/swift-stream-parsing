import { useEffect, useState } from "react";
import { loadAssembly, loadSources } from "../data";
import type { DocSection, PipelineNode, SourceDecl, TraceBundle } from "../types";
import { Visualization } from "../viz";
import { Markdown, VerdictChip } from "./Markdown";

type Tab = "explanation" | "experiments" | "source" | "assembly";

const REPO = "https://github.com/mhayes853/swift-stream-parsing/blob/main";

export function DetailPanel({
  node,
  sections,
  traces,
  onClose
}: {
  node: PipelineNode;
  sections: Map<string, DocSection>;
  traces: TraceBundle | null;
  onClose: () => void;
}) {
  const [tab, setTab] = useState<Tab>("explanation");

  useEffect(() => setTab("explanation"), [node.id]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const docs = node.evidence.doc.map((path) => sections.get(path)).filter((s): s is DocSection => !!s);
  const experiments = docs.filter((s) => s.verdict !== "neutral");
  const explanations = docs.filter((s) => s.verdict === "neutral");

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
            <TabButton id="explanation" tab={tab} setTab={setTab} label="Explanation" count={explanations.length} />
            <TabButton id="experiments" tab={tab} setTab={setTab} label="Experiments" count={experiments.length} />
            <TabButton id="source" tab={tab} setTab={setTab} label="Source" count={node.evidence.source.length} />
            <TabButton id="assembly" tab={tab} setTab={setTab} label="Assembly" count={node.evidence.asm.length} />
          </div>
        </div>
        <div className="panel-body">
          {tab === "explanation" && <Explanation node={node} sections={explanations} traces={traces} />}
          {tab === "experiments" && <Experiments sections={experiments} />}
          {tab === "source" && <Source keys={node.evidence.source} />}
          {tab === "assembly" && <Assembly symbols={node.evidence.asm} />}
        </div>
      </aside>
    </>
  );
}

function TabButton({
  id,
  tab,
  setTab,
  label,
  count
}: {
  id: Tab;
  tab: Tab;
  setTab: (t: Tab) => void;
  label: string;
  count: number;
}) {
  return (
    <button role="tab" aria-selected={tab === id} onClick={() => setTab(id)}>
      {label}
      <span className="count">{count}</span>
    </button>
  );
}

function Explanation({
  node,
  sections,
  traces
}: {
  node: PipelineNode;
  sections: DocSection[];
  traces: TraceBundle | null;
}) {
  return (
    <>
      {node.viz && (
        <div style={{ marginBottom: 20 }}>
          <Visualization kind={node.viz} traces={traces} />
        </div>
      )}
      <div className="md">
        {node.prose.map((p, i) => (
          <p key={i} style={{ color: i === 0 ? "var(--text-primary)" : undefined, fontSize: i === 0 ? 16 : undefined }}>
            {p}
          </p>
        ))}
      </div>
      {sections.length > 0 && (
        <>
          <h3 style={{ fontSize: 13, textTransform: "uppercase", letterSpacing: "0.05em", color: "var(--text-muted)", marginTop: 28 }}>
            From the architecture log
          </h3>
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
  // Rejections first: they are the ones that stop a decision being re-litigated.
  const order = { rejected: 0, mixed: 1, landed: 2, neutral: 3 } as const;
  const sorted = [...sections].sort((a, b) => order[a.verdict] - order[b.verdict]);
  return (
    <>
      <p className="callout">
        Measured on arm64 (M1 Pro), each against its own control. Rejected results are listed first.
      </p>
      {sorted.map((section) => (
        <SectionCard key={section.path} section={section} defaultOpen={sorted.length <= 2} />
      ))}
    </>
  );
}

function SectionCard({ section, defaultOpen = false }: { section: DocSection; defaultOpen?: boolean }) {
  const chapter = section.chapter === section.title ? null : section.chapter;
  return (
    <details className="evidence-item" open={defaultOpen}>
      <summary>
        <span style={{ flex: 1 }}>{section.title}</span>
        <VerdictChip verdict={section.verdict} />
      </summary>
      <div className="summary-line">
        <span className="where">
          NEW_ARCHITECTURE.md:{section.line}
          {chapter ? ` · ${chapter}` : ""}
          {section.tables.length > 0 ? ` · ${section.tables.length} table${section.tables.length === 1 ? "" : "s"}` : ""}
        </span>
      </div>
      <div className="evidence-body">
        <Markdown>{section.markdown}</Markdown>
        <a
          href={`${REPO}/NEW_ARCHITECTURE.md#L${section.line}`}
          target="_blank"
          rel="noreferrer"
          style={{ fontSize: 12.5 }}
        >
          Open in the repository ↗
        </a>
      </div>
    </details>
  );
}

function Source({ keys }: { keys: string[] }) {
  const [decls, setDecls] = useState<Record<string, SourceDecl[]> | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    loadSources().then(
      (bundle) => setDecls(bundle.sources),
      (e) => setError(String(e))
    );
  }, []);

  if (error) return <p className="empty">{error}</p>;
  if (!decls) return <p className="empty">Loading declarations…</p>;
  if (keys.length === 0) return <p className="empty">No source attached to this step.</p>;

  return (
    <>
      {keys.map((key) => {
        const matches = decls[key] ?? [];
        return matches.map((decl, i) => (
          <details className="evidence-item" key={`${key}-${i}`} open={matches.length === 1 && keys.length <= 2}>
            <summary>
              <span style={{ flex: 1, fontFamily: "var(--font-mono)", fontSize: 14 }}>
                {decl.qualifiedName}
                {matches.length > 1 ? ` (${i + 1}/${matches.length})` : ""}
              </span>
              <span className="kicker">{decl.kind}</span>
            </summary>
            <div className="summary-line">
              <span className="where">
                {decl.file}:{decl.startLine}–{decl.endLine}
                {decl.attributes.length > 0 ? ` · ${decl.attributes.join(" ")}` : ""}
              </span>
            </div>
            <div className="evidence-body">
              {decl.comment && (
                <>
                  <h4 style={{ fontSize: 12, textTransform: "uppercase", letterSpacing: "0.05em", color: "var(--text-muted)", margin: "0 0 8px" }}>
                    Why, from the source
                  </h4>
                  <Markdown>{decl.comment}</Markdown>
                </>
              )}
              <pre>
                <code>{decl.code}</code>
              </pre>
              {decl.members.length > 0 && (
                <p style={{ fontSize: 12.5, color: "var(--text-muted)" }}>
                  Body elided. {decl.members.length} members: <code>{decl.members.join(", ")}</code>
                </p>
              )}
              <a
                href={`${REPO}/${decl.file}#L${decl.startLine}-L${decl.endLine}`}
                target="_blank"
                rel="noreferrer"
                style={{ fontSize: 12.5 }}
              >
                Open in the repository ↗
              </a>
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
    symbols.forEach((symbol) => {
      loadAssembly(symbol).then(
        (text) => setListings((prev) => ({ ...prev, [symbol]: text })),
        (e) => setListings((prev) => ({ ...prev, [symbol]: `; ${e}` }))
      );
    });
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
      {symbols.map((symbol) => {
        const text = listings[symbol];
        const header = text?.split("\n").filter((l) => l.startsWith(";")) ?? [];
        return (
          <details className="evidence-item" key={symbol}>
            <summary>
              <span style={{ flex: 1, fontFamily: "var(--font-mono)", fontSize: 14 }}>{symbol}</span>
              <span className="kicker">
                {header.find((l) => l.includes("instructions"))?.replace("; ", "") ?? "…"}
              </span>
            </summary>
            <div className="evidence-body">
              <pre style={{ maxHeight: 420 }}>
                <code>{text ?? "Loading…"}</code>
              </pre>
            </div>
          </details>
        );
      })}
    </>
  );
}
