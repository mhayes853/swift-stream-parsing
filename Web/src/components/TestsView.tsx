import { useMemo } from "react";
import { repoURL } from "../lib/evidence";
import { fileOf, nameOf, resolveGuarantee, techniquesOf, testTotals } from "../lib/tests";
import type { Guarantee, LibraryBundle, SourceDecl, TestsContent, TraceBundle } from "../types";
import { ChunkCutViz } from "../viz/ChunkCutViz";
import { Code } from "./highlight";
import { inline } from "./Markdown";

function DeclLink({ decl, children }: { decl: SourceDecl; children: React.ReactNode }) {
  return (
    <a href={repoURL(decl.file, decl.startLine, decl.endLine)} target="_blank" rel="noreferrer">
      {children}
    </a>
  );
}

/** A cited declaration: its name, where it is, and its leading comment when it has one. */
function Citation({ citation, library }: { citation: string; library: LibraryBundle }) {
  const decl = library.decls[citation];
  const name = nameOf(citation);
  return (
    <details className="evidence-item test-citation">
      <summary>
        <span className="summary-head">
          <span style={{ flex: 1 }}>{name}</span>
          <span className="where">{fileOf(citation)}</span>
        </span>
      </summary>
      {decl && (
        <div className="evidence-body">
          {decl.comment && <p className="test-comment">{decl.comment}</p>}
          <Code language="swift">{decl.code}</Code>
          <p className="provenance">
            <DeclLink decl={decl}>
              {decl.file}:{decl.startLine}
            </DeclLink>
          </p>
        </div>
      )}
    </details>
  );
}

function GuaranteeCard({
  guarantee,
  content,
  library,
  traces,
  titleOf,
  onNode
}: {
  guarantee: Guarantee;
  content: TestsContent;
  library: LibraryBundle;
  traces: TraceBundle | null;
  titleOf: (id: string) => string | undefined;
  onNode: (id: string) => void;
}) {
  const resolved = useMemo(() => resolveGuarantee(library, guarantee), [library, guarantee]);
  const showcase = library.decls[guarantee.showcase];
  const suiteComments = guarantee.suites.flatMap((key) => {
    const decl = library.decls[key];
    return decl?.comment ? [{ key, decl }] : [];
  });

  return (
    <article className="guarantee" id={`guarantee-${guarantee.id}`}>
      <h3>{guarantee.title}</h3>
      {guarantee.why.map((p, i) => (
        <p key={i}>{inline(p, `w${i}`)}</p>
      ))}

      <div className="guarantee-meta">
        {techniquesOf(content, guarantee).map((t) => (
          <a key={t.id} className="chip" href={`#technique-${t.id}`} onClick={(e) => {
            e.preventDefault();
            document.getElementById(`technique-${t.id}`)?.scrollIntoView({ behavior: "smooth", block: "center" });
          }}>
            {t.title}
          </a>
        ))}
        {guarantee.node.map((id) => (
          <button key={id} className="chip node-chip" onClick={() => onNode(id)}>
            {titleOf(id) ?? id} →
          </button>
        ))}
      </div>

      {guarantee.viz === "chunkCuts" && traces && <ChunkCutViz trace={traces.chunkCuts} />}

      {suiteComments.map(({ key, decl }) => (
        <blockquote key={key} className="test-suite-comment">
          <p>{decl.comment}</p>
          <footer>
            <DeclLink decl={decl}>{nameOf(key)}</DeclLink> · {decl.file}
          </footer>
        </blockquote>
      ))}

      <h4 className="guarantee-sub">
        The tests · {resolved.tests.length} cited of {resolved.related} in these files
      </h4>
      <ul className="guarantee-tests">
        {resolved.tests.map((t) => (
          <li key={t.key}>
            <a href={repoURL(t.file, t.line)} target="_blank" rel="noreferrer">
              {t.name}
            </a>
            <span className="where">
              {fileOf(t.key)}
              {t.parameterized && " · parameterized"}
            </span>
          </li>
        ))}
      </ul>

      {showcase && (
        <details className="guarantee-showcase">
          <summary>
            Read one: <strong>{nameOf(guarantee.showcase)}</strong>
          </summary>
          {showcase.comment && <p className="test-comment">{showcase.comment}</p>}
          <Code language="swift">{showcase.code}</Code>
          <p className="provenance">
            <DeclLink decl={showcase}>
              {showcase.file}:{showcase.startLine}
            </DeclLink>
          </p>
        </details>
      )}
    </article>
  );
}

export function TestsView({
  content,
  library,
  error,
  traces,
  titleOf,
  onNode
}: {
  content: TestsContent;
  library: LibraryBundle | null;
  error: string | null;
  traces: TraceBundle | null;
  titleOf: (id: string) => string | undefined;
  onNode: (id: string) => void;
}) {
  const totals = library ? testTotals(library) : null;
  const suites = library ? new Set(library.tests.cases.map((c) => `${c.file}:${c.suite}`)).size : 0;

  return (
    <section className="library-view">
      <h2 className="view-title">Tests</h2>
      {content.lede.map((p, i) => (
        <p key={i} className="section-lead">
          {inline(p, `l${i}`)}
        </p>
      ))}

      {error && <p className="callout warn">Could not load the test index: {error}</p>}
      {!library && !error && <p className="empty">Loading the test index…</p>}

      {library && totals && (
        <>
          <div className="stat-row">
            <Stat value={totals.tests} label="@Test declarations" />
            <Stat value={totals.parameterized} label="parameterized" />
            <Stat value={suites} label="suites" />
            <Stat value={content.guarantees.length} label="guarantees below" />
          </div>
          <div className="table-scroll">
          <table className="test-targets">
            <thead>
              <tr>
                <th>Target</th>
                <th style={{ textAlign: "right" }}>Files</th>
                <th style={{ textAlign: "right" }}>Tests</th>
                <th style={{ textAlign: "right" }}>Parameterized</th>
              </tr>
            </thead>
            <tbody>
              {library.tests.targets.map((t) => (
                <tr key={t.name}>
                  <td>
                    <code>{t.path}</code>
                  </td>
                  <td style={{ textAlign: "right" }}>{t.files}</td>
                  <td style={{ textAlign: "right" }}>{t.tests === 0 ? "smoke package" : t.tests}</td>
                  <td style={{ textAlign: "right" }}>{t.tests === 0 ? "—" : t.parameterized}</td>
                </tr>
              ))}
            </tbody>
          </table>
          </div>

          <h2 className="panel-rule">How the suites know the right answer</h2>
          <div className="techniques">
            {content.techniques.map((t) => (
              <article key={t.id} id={`technique-${t.id}`} className="technique">
                <h3>{t.title}</h3>
                <p>{inline(t.detail, t.id)}</p>
                {t.refs.map((ref) => (
                  <Citation key={ref} citation={ref} library={library} />
                ))}
              </article>
            ))}
          </div>

          <h2 className="panel-rule">What the tests guarantee</h2>
          <nav className="guarantee-index" aria-label="Guarantees">
            {content.guarantees.map((g, i) => (
              <a
                key={g.id}
                href={`#guarantee-${g.id}`}
                onClick={(e) => {
                  e.preventDefault();
                  document.getElementById(`guarantee-${g.id}`)?.scrollIntoView({ behavior: "smooth" });
                }}
              >
                <span className="overview-step">{i + 1}</span>
                {g.title}
              </a>
            ))}
          </nav>
          {content.guarantees.map((g) => (
            <GuaranteeCard
              key={g.id}
              guarantee={g}
              content={content}
              library={library}
              traces={traces}
              titleOf={titleOf}
              onNode={onNode}
            />
          ))}
        </>
      )}
    </section>
  );
}

function Stat({ value, label }: { value: number; label: string }) {
  return (
    <div className="stat">
      <div className="value">{value}</div>
      <div className="label">{label}</div>
    </div>
  );
}

