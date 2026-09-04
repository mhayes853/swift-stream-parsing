import type { FrameTrace } from "../types";
import type { TapeMark } from "./common";
import { Facts, InputTape, StepBar, StepNote, phaseOf, useSteps } from "./common";

// The frame stack, and what borrows what.
//
// Both animations below step the same recording: a sink that forwards every call to a real
// `PartialSink` and then reads the sink's own `frames` and `frameCount` back out. Nothing here is
// reconstructed from the event stream — it is the stack the sink kept, and the value it produced
// is printed underneath so the whole thing is checkable rather than merely plausible.

const CALL_NOTE: Record<string, string> = {
  beginObject: "A container opens: a frame is pushed over the member's address.",
  beginArray: "A container opens: a frame is pushed over the member's address.",
  endObject: "The container closes: the frame is popped. A store and a decrement — the frame is trivial, so there is no ARC to unwind.",
  endArray: "The container closes: the frame is popped.",
  key: "The key resolves to an entry index and is parked in the top frame's pendingField. Nothing is written yet.",
  number: "The scalar the pending field was waiting for: a typed store at storage + offset.",
  string: "The scalar the pending field was waiting for: appended in place at storage + offset.",
  stringBegin: "The destination is asked whether it takes strings at all, before any bytes arrive.",
  stringChunk: "Bytes appended in place.",
  stringEnd: "The string is complete.",
  boolean: "A typed store at storage + offset.",
  null: "A null: the member is cleared, or refused if it is not optional."
};

/** The root value's storage, one box per declared member, with the one being written marked. */
function Storage({
  trace,
  writing,
  frameOffsets
}: {
  trace: FrameTrace;
  writing?: string | null;
  /** Storage offsets of the frames above the root. The root's own frame stands over the whole
      value, not over its first member, so including it would ring `id` at offset 0. */
  frameOffsets: (number | null | undefined)[];
}) {
  const members = trace.members.filter((m) => m.schema === 0);
  return (
    <div className="storage">
      <div className="storage-head">
        <code>{trace.schemas[0]?.name}</code>
        <span>{trace.rootSize} bytes</span>
      </div>
      <div className="storage-row">
        {members.map((member) => {
          const nested =
            member.kind === "container" ? trace.members.filter((m) => m.schema === 1) : [];
          const framed = member.kind === "container" && frameOffsets.includes(member.offset);
          return (
            <div
              key={member.name}
              className={`storage-cell ${writing === member.name ? "writing" : ""} ${
                framed ? "framed" : ""
              }`}
              style={{ flexGrow: member.size }}
              title={`${member.name}: ${member.kind}, ${member.size} bytes at +${member.offset}`}
            >
              <span className="storage-name">{member.name}</span>
              <span className="storage-meta">
                +{member.offset} · {member.size}B
              </span>
              {member.kind === "container" && (
                <div className="storage-nest">
                  {nested.map((child) => (
                    <span
                      key={child.name}
                      className={writing === child.name ? "writing" : ""}
                      title={`${child.name}: ${child.kind}, ${child.size} bytes at +${
                        member.offset + child.offset
                      }`}
                    >
                      {child.name}
                    </span>
                  ))}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}

/**
 * `PartialSink`, one call at a time.
 *
 * The stack is one fixed allocation rather than an `Array`, because the parser caps depth and so
 * the bound is known: what that buys is not the allocation but the bookkeeping an `Array` charges
 * to be resizable — a uniqueness check on every mutation and a bounds check on every read, both of
 * which a key used to pay per key.
 */
export function FramesViz({ trace }: { trace: FrameTrace }) {
  const steps = trace.steps;
  const { index, setIndex, playing, play } = useSteps(steps.length, 950);
  const step = steps[index];
  if (!step) return null;

  const previous = steps[index - 1];
  const marks: TapeMark[] = [];
  const lastOffset = steps
    .slice(0, index)
    .map((s) => (s.offset ?? null) !== null ? s.offset! + (s.length ?? 0) : null)
    .filter((n): n is number => n !== null)
    .pop();
  if (lastOffset !== undefined) marks.push({ from: 0, to: lastOffset, kind: "done" });
  if (step.offset !== null && step.offset !== undefined) {
    marks.push({ from: step.offset, to: step.offset + (step.length ?? 1), kind: "cursor" });
  }

  const pushed = step.frames.length > (previous?.frames.length ?? 0);
  const popped = step.frames.length < (previous?.frames.length ?? 0);

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={steps.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Sink call"
      />

      <StepNote op={step.call}>
        {CALL_NOTE[step.call] ?? "—"}
        {step.wrote && ` Member ${step.wrote}.`}
      </StepNote>

      <InputTape bytes={trace.bytes} marks={marks} blockSize={0} label="the document" />

      <div className="frames-split">
        {/* Top of stack at the top, because that is where the parser is. */}
        <div className="frame-stack">
          <span className="frame-stack-label">
            frames · {step.frames.length}
            {pushed && <em> pushed</em>}
            {popped && <em> popped</em>}
          </span>
          {[...step.frames].reverse().map((frame, position) => {
            const schema = trace.schemas[frame.schema];
            const depth = step.frames.length - 1 - position;
            return (
              <div
                key={`${index}-${depth}`}
                className={`frame ${position === 0 ? "top" : ""} ${
                  pushed && position === 0 ? "chg" : ""
                }`}
              >
                <code>{schema?.name ?? "?"}</code>
                <span className="frame-storage">
                  storage +{frame.storageOffset ?? "?"}
                </span>
                <span className={`frame-pending ${frame.field ? "set" : ""}`}>
                  pendingField {frame.pendingField}
                  {frame.field ? ` · ${frame.field}` : " · none"}
                </span>
              </div>
            );
          })}
          {step.frames.length === 0 && (
            <div className="frame empty">the stack is empty — the document is done</div>
          )}
        </div>

        <div>
          <Storage
            trace={trace}
            writing={step.wrote}
            frameOffsets={step.frames.slice(1).map((f) => f.storageOffset)}
          />
          <Facts
            items={[
              ["call", <code key="c">{step.call}</code>],
              [
                "argument",
                step.text !== null && step.text !== undefined ? (
                  <code key="a">{JSON.stringify(step.text)}</code>
                ) : (
                  "—"
                )
              ],
              ["depth", String(step.frames.length)],
              ["wrote", step.wrote ? <code key="w">{step.wrote}</code> : "nothing"]
            ]}
          />
        </div>
      </div>

      <p className="viz-caption">
        A key does not write anything: it resolves to a table index and parks it in the top frame,
        and the scalar that follows is what turns that index into a typed store at{" "}
        <code>storage + offset</code>. Nothing is called for the kinds the library knows the layout
        of — the closures survive only for a type it cannot see into, and for entering a container,
        which is once per container rather than once per value.
      </p>

      <p className="viz-note">
        The parse produced <code>{trace.result}</code>.
        {!trace.verified && (
          <strong style={{ color: "var(--warning)" }}>
            {" "}
            ⚠ The destination did not hold what the document said.
          </strong>
        )}
      </p>
    </div>
  );
}

/**
 * The schemas the frames point at.
 *
 * A schema is built once, before any parsing, and every frame over it borrows it
 * `unowned(unsafe)`. That is the claim; this steps a real parse and counts. The schema objects do
 * not change and are never allocated again, while frames come and go — and a frame carrying a
 * schema is a store rather than a retain, which is what makes pushing one a store and a decrement.
 */
export function SchemaRoutingViz({ trace }: { trace: FrameTrace }) {
  const steps = trace.steps;
  const { index, setIndex, playing, play } = useSteps(steps.length, 900);
  const step = steps[index];
  if (!step) return null;

  const pushesSoFar = steps
    .slice(0, index + 1)
    .filter((s) => s.call === "beginObject" || s.call === "beginArray").length;
  const live = new Map<number, number>();
  for (const frame of step.frames) live.set(frame.schema, (live.get(frame.schema) ?? 0) + 1);

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={steps.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Sink call"
      />

      <StepNote op={step.call}>
        {step.call === "key" ? (
          <>
            The key is routed by one byte on the schema —{" "}
            <code>{trace.schemas[step.frames[step.frames.length - 1]?.schema]?.keyRouting}</code> —
            not by a shape test followed by a matcher test.
          </>
        ) : step.call === "beginObject" || step.call === "beginArray" ? (
          <>
            Frame {pushesSoFar} borrows a schema that already existed. No schema is allocated here.
          </>
        ) : (
          <>The active schema is unchanged; the value is written through the frame that holds it.</>
        )}
      </StepNote>

      <div className="schema-grid">
        {trace.schemas.map((schema) => {
          const borrows = live.get(schema.id) ?? 0;
          return (
            <div key={schema.id} className={`schema-card ${borrows > 0 ? "live" : ""}`}>
              <code>{schema.name}</code>
              <Facts
                items={[
                  ["shape", schema.shape],
                  [
                    "keyRouting",
                    <code key="r">{schema.keyRouting}</code>
                  ],
                  ["fields", String(schema.fieldCount)],
                  [
                    "borrowed by",
                    borrows === 0 ? "no frame right now" : `${borrows} frame${borrows === 1 ? "" : "s"}`
                  ]
                ]}
              />
            </div>
          );
        })}
      </div>

      <ol className="call-log compact">
        {steps.map((entry, position) => (
          <li
            key={entry.index}
            className={`call ${phaseOf(position, index)}`}
            onClick={() => setIndex(position)}
            role="button"
          >
            <code className="call-method">{entry.call}</code>
            {phaseOf(position, index) === "future" ? null : (
              <span className="call-depth">
                {entry.frames.map((f) => trace.schemas[f.schema]?.name.replace("Trace", "")).join(" › ") ||
                  "—"}
              </span>
            )}
          </li>
        ))}
      </ol>

      <p className="viz-caption">
        {trace.schemas.length} schema objects, built once and never again. {pushesSoFar} frame
        {pushesSoFar === 1 ? " has" : "s have"} been pushed over them so far, each one borrowing
        rather than owning: the frame stack, the pending dictionary frame and the scalar target all
        stop retaining, so a push is a store and a pop is a decrement.
      </p>

      <p className="viz-note">
        Sound only while every schema a frame can carry outlives the parse — which holds, because a
        container member's schema is the static its parent hoists and an ignored subtree's is a
        shared singleton. A debug build checks it with <code>StreamSchemaBorrowAudit</code> rather
        than trusting it.
      </p>
    </div>
  );
}
