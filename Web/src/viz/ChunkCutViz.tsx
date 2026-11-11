import { cutSummary } from "../lib/tests";
import type { TapeMark } from "../lib/viz";
import type { ChunkCutTrace, Delivery } from "../types";
import { DriftedInline, InputTape, StepBar, StepNote, useSteps } from "./common";

const DELIVERY: Record<Delivery, { label: string; short: string }> = {
  head: { label: "the first call", short: "1st" },
  tail: { label: "the second call", short: "2nd" },
  both: { label: "both calls", short: "both" },
  finish: { label: "finish()", short: "fin" }
};

function tokenLabel(token: { kind: string; text: string }): string {
  switch (token.kind) {
    case "key":
      return `key ${token.text}`;
    case "string":
      return `"${token.text}"`;
    default:
      return token.text;
  }
}

function note(trace: ChunkCutTrace, index: number) {
  const summary = cutSummary(trace, index);
  const token = summary.straddling === undefined ? undefined : trace.tokens[summary.straddling];
  const delivery = summary.straddling === undefined ? undefined : trace.splits[index].delivery[summary.straddling];
  const lead = (
    <>
      Cut before byte {summary.at}: the first call gets {summary.at} {summary.at === 1 ? "byte" : "bytes"} and delivers{" "}
      {summary.head}{" "}
      {summary.head === 1 ? "token" : "tokens"}.
    </>
  );
  if (!token || !delivery) return lead;
  if (delivery === "both") {
    return (
      <>
        {lead} The cut runs through the string <code>{tokenLabel(token)}</code>: its content streams, so the
        first call delivers what it holds and the second the rest.
      </>
    );
  }
  if (token.kind === "key" || token.kind === "number" || token.kind === "boolean" || token.kind === "null") {
    return (
      <>
        {lead} <code>{tokenLabel(token)}</code> is next. A {token.kind === "key" ? "key" : token.kind === "number" ? "number" : "literal"}{" "}
        is delivered whole, so if the cut runs through it the parser holds the first part and the second call delivers it.
      </>
    );
  }
  return (
    <>
      {lead} Everything from <code>{tokenLabel(token)}</code> on arrives in the second call.
    </>
  );
}

export function ChunkCutViz({ trace }: { trace: ChunkCutTrace }) {
  const player = useSteps(trace.splits.length, 420);
  const index = player.index;
  const split = trace.splits[index];
  const marks: TapeMark[] = [
    { from: 0, to: split.at, kind: "done" },
    { from: split.at, to: split.at + 1, kind: "next" }
  ];

  return (
    <div className="viz chunk-cut-viz">
      <StepBar player={player} label="Cut point" />
      <StepNote op={`split ${split.at}`}>{note(trace, index)}</StepNote>
      <InputTape
        bytes={trace.bytes}
        marks={marks}
        blockSize={0}
        label="the document"
        caption={<>The shaded bytes go to the first call; the outlined byte is the first of the second.</>}
      />

      <div className="cut-legend" aria-hidden="true">
        {(["head", "both", "tail"] as const).map((d) => (
          <span key={d}>
            <i className={`cut-cell ${d}`}>{DELIVERY[d].short}</i> delivered by {DELIVERY[d].label}
          </span>
        ))}
      </div>

      <div className="cut-grid-scroll">
        <table className="cut-grid" aria-label="Which call delivered each token, at every cut point">
          <thead>
            <tr>
              <th scope="col">token</th>
              {trace.splits.map((s, i) => (
                <th key={s.at} scope="col" className={i === index ? "now" : undefined}>
                  <button
                    className="cut-col"
                    aria-label={`Cut before byte ${s.at}`}
                    aria-pressed={i === index}
                    onClick={() => player.seek(i)}
                  />
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {trace.tokens.map((token, t) => (
              <tr key={t}>
                <th scope="row">
                  <code>{tokenLabel(token)}</code>
                </th>
                {trace.splits.map((s, i) => {
                  const d = s.delivery[t];
                  return (
                    <td
                      key={s.at}
                      className={`cut-cell ${d}${i === index ? " now" : ""}`}
                      title={`cut before byte ${s.at}: ${tokenLabel(token)} delivered by ${DELIVERY[d].label}`}
                      onClick={() => player.seek(i)}
                    />
                  );
                })}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <ol className="cut-tokens" aria-label={`Tokens at the cut before byte ${split.at}`}>
        {trace.tokens.map((token, t) => {
          const d = split.delivery[t];
          return (
            <li key={t} className={d}>
              <code>{tokenLabel(token)}</code>
              <span>{DELIVERY[d].label}</span>
            </li>
          );
        })}
      </ol>

      <p className="viz-note">
        Recorded by running the shipped parser on this document cut before every byte, {trace.splits.length}{" "}
        times. At every cut the tokens, strings joined back up, equal the whole document's: the property{" "}
        <code>expectChunkBoundaryEquivalence</code> checks on finished values.
        {!trace.verified && <DriftedInline>A cut produced different tokens from the whole parse.</DriftedInline>}
      </p>
    </div>
  );
}
