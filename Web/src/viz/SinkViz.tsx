import { cx } from "../lib/cx";
import type { RowPhase, TapeMark } from "../lib/viz";
import { phaseOf, readUpTo } from "../lib/viz";
import type { DispositionTrace, SinkCall, SinkCallTrace } from "../types";
import { Drifted, Facts, InputTape, StepBar, StepNote, useSteps } from "./common";

// The two animations of the boundary itself: what the parser calls, and what it stops calling
// when the sink says it does not want a subtree.
//
// Neither is a kernel, so neither is drawn as registers. What matters here is a *sequence of
// calls* and, for each one, which bytes of the input the span it carries is pointing at — because
// "the span is invalid once the call returns" is a claim about those bytes, and it is the whole
// reason the surface is zero-copy.

const GROUP_LABEL: Record<SinkCall["group"], string> = {
  structure: "structure",
  key: "key",
  whole: "whole value",
  chunked: "chunked string"
};

/** One row of a call log. A future row keeps its box and shows nothing, so nothing reflows. */
function CallRow({
  call,
  phase,
  elided,
  onSeek
}: {
  call: SinkCall;
  phase: RowPhase;
  elided?: boolean;
  onSeek?: () => void;
}) {
  return (
    <li
      className={cx("call", phase, elided && "elided", `group-${call.group}`)}
      onClick={onSeek}
      role={onSeek ? "button" : undefined}
    >
      <code className="call-method">{call.method}</code>
      {phase === "future" ? null : (
        <>
          {call.text != null && <span className="call-arg">{JSON.stringify(call.text)}</span>}
          {call.takesSpan && (
            <span className="call-span">
              {call.offset == null ? "span → scratch" : `span @ ${call.offset}+${call.length}`}
            </span>
          )}
          <span className="call-depth">d{call.depthAfter}</span>
        </>
      )}
    </li>
  );
}

/**
 * The call log: every method the parser called, in order, with the span it passed.
 *
 * These are not reconstructed events — a sink recorded them while a real parse ran, and each span
 * offset is the parser's own answer to "which bytes is this", checked against the bytes the call
 * reports. The one call here whose span reports *no* offset is the escape: those bytes were
 * unescaped into scratch storage and no longer point into the document, which is exactly the case
 * the borrow rule exists for.
 */
export function SinkCallsViz({ trace }: { trace: SinkCallTrace }) {
  const calls = trace.calls;
  const player = useSteps(calls.length, 850);
  const { index } = player;
  const call = calls[index];
  if (!call) return null;

  const start = call.offset ?? null;
  const marks: TapeMark[] = [];
  const read = readUpTo(calls, index);
  if (read !== undefined) marks.push({ from: 0, to: read, kind: "done" });
  if (start !== null) marks.push({ from: start, to: start + (call.length ?? 0), kind: "cursor" });

  const scratch = call.takesSpan && call.offset == null;
  const spanCalls = calls.filter((c) => c.takesSpan).length;

  return (
    <div className="viz">
      <StepBar player={player} label="Sink call" />

      <StepNote op={call.method}>
        {call.takesSpan
          ? scratch
            ? "The span points at the parser's scratch storage, not at the document: this chunk is a decoded escape, so there are no input bytes to point at."
            : `A borrowed span over bytes ${start}–${(start ?? 0) + (call.length ?? 1) - 1}. Valid until this call returns, and not one byte longer.`
          : call.group === "structure"
            ? `No span, no argument: the call itself is the token. Depth is now ${call.depthAfter}.`
            : "No span: the value is the argument."}
      </StepNote>

      <InputTape
        bytes={trace.bytes}
        marks={marks}
        blockSize={0}
        label="the document"
        caption={
          <>
            {spanCalls} of these {calls.length} calls carry a span. The rest carry nothing at all —
            a container open takes no argument, so there is nothing to copy and nothing to free.
          </>
        }
      />

      <div className="sink-split">
        <ol className="call-log">
          {calls.map((entry, position) => (
            <CallRow
              key={entry.index}
              call={entry}
              phase={phaseOf(position, index)}
              onSeek={() => player.seek(position)}
            />
          ))}
        </ol>

        <div className="sink-detail">
          <code className="sink-signature">{call.signature}</code>
          <Facts
            items={[
              ["group", GROUP_LABEL[call.group]],
              ["carries", call.takesSpan ? <code>Span&lt;UInt8&gt;</code> : "no span"],
              [
                "argument",
                call.text != null ? <code>{JSON.stringify(call.text)}</code> : "—"
              ],
              ["depth after", String(call.depthAfter)],
              ["throws", "no — the sink records a failure and the parser polls it"]
            ]}
          />
        </div>
      </div>

      <p className="viz-caption">
        {call.group === "chunked" ? (
          <>
            The fallback form. A string that carries an escape cannot be one borrow of the input,
            so it arrives as <code>stringBegin</code>, chunks, <code>stringEnd</code> — and a sink
            that ignores these is wrong on chunked input rather than merely slower.
          </>
        ) : call.group === "whole" && call.method === "string" ? (
          <>
            The common form: complete in the chunk and escape-free, so the whole value is one call
            over the input's own bytes. Nothing was copied to produce it.
          </>
        ) : call.group === "key" ? (
          <>
            A key is always whole. The parser reassembles one that a chunk boundary or an escape
            cut, so a sink never sees half of a key and never has to hold one across a call.
          </>
        ) : (
          <>
            The two opens are the only calls that return anything: a{" "}
            <code>StreamContainerDisposition</code>, which is where a sink says it has no use for
            the subtree about to arrive.
          </>
        )}
      </p>

      {!trace.verified && <Drifted>A span did not cover the bytes its call reported.</Drifted>}
    </div>
  );
}

/**
 * The same document, delivered to two sinks.
 *
 * Both runs below are real parses of the same bytes; the only difference is what one sink answered
 * when a container opened. The interior calls do not arrive late or arrive empty — they do not
 * happen, and the parser scanned those bytes structurally instead. The matching close still
 * arrives, which is the half of the contract that lets a `PartialSink` pop the frame it pushed.
 */
export function DispositionsViz({ trace }: { trace: DispositionTrace }) {
  const steps = trace.streamed;
  const player = useSteps(steps.length, 800);
  const { index } = player;
  const call = steps[index];
  if (!call) return null;

  const delivered = trace.delivered[index];
  const elidedCount = trace.delivered.filter((d) => !d).length;

  const marks: TapeMark[] = [
    { from: trace.skipFrom, to: trace.skipTo, kind: "window" },
    ...(call.offset != null
      ? [{ from: call.offset, to: call.offset + (call.length ?? 1), kind: "cursor" as const }]
      : [])
  ];

  return (
    <div className="viz">
      <StepBar player={player} label="Token" />

      <StepNote op={call.method}>
        {delivered
          ? "Both sinks receive this call."
          : "The streaming sink receives this. The skipping sink does not — the parser is inside the subtree it refused."}
      </StepNote>

      <InputTape
        bytes={trace.bytes}
        marks={marks}
        blockSize={0}
        label="the document"
        caption={
          <>
            The shaded range is the subtree the second sink refused, bytes {trace.skipFrom}–
            {trace.skipTo - 1}. Its interior is still validated structurally — brackets must match
            and strings must terminate — but nothing in it is lexed into a token.
          </>
        }
      />

      <div className="disposition-grid">
        <div>
          <h5>
            <code>.stream</code>
            <span>{trace.streamed.length} calls</span>
          </h5>
          <ol className="call-log">
            {steps.map((entry, position) => (
              <CallRow
                key={entry.index}
                call={entry}
                phase={phaseOf(position, index)}
                onSeek={() => player.seek(position)}
              />
            ))}
          </ol>
        </div>
        <div>
          <h5>
            <code>.skip</code> at <code>{JSON.stringify(trace.skippedKey)}</code>
            <span>{trace.skipped.length} calls</span>
          </h5>
          <ol className="call-log">
            {steps.map((entry, position) => (
              <CallRow
                key={entry.index}
                call={entry}
                phase={phaseOf(position, index)}
                elided={!trace.delivered[position]}
                onSeek={() => player.seek(position)}
              />
            ))}
          </ol>
        </div>
      </div>

      <p className="viz-caption">
        {elidedCount} of {steps.length} calls never happen. What that buys is not the calls: the
        subtree's interior runs at structural-scan speed, with no key matching, no number parse and
        no escape decode. The answer is advisory — a deliverer that has already recorded the
        subtree hands it over anyway — so a sink that answers <code>.skip</code> still has to be
        correct receiving it.
      </p>

      {!trace.verified && <Drifted>The skipping run was not a subsequence of the streaming one.</Drifted>}
    </div>
  );
}
