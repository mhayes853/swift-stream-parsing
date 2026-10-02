import { cx } from "../lib/cx";
import type { TapeMark } from "../lib/viz";
import { phaseOf, readUpTo } from "../lib/viz";
import type { FrameTrace } from "../types";
import { DriftedInline, Facts, InputTape, StepBar, StepNote, useSteps } from "./common";

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

function Storage({
  trace,
  writing,
  frameOffsets
}: {
  trace: FrameTrace;
  writing?: string | null;
  // Excludes the root frame, which would otherwise ring the member at offset 0.
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
              className={cx("storage-cell", writing === member.name && "writing", framed && "framed")}
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

export function FramesViz({ trace }: { trace: FrameTrace }) {
  const steps = trace.steps;
  const player = useSteps(steps.length, 950);
  const { index } = player;
  const step = steps[index];
  if (!step) return null;

  const previous = steps[index - 1];
  const marks: TapeMark[] = [];
  const read = readUpTo(steps, index);
  if (read !== undefined) marks.push({ from: 0, to: read, kind: "done" });
  if (step.offset != null) {
    marks.push({ from: step.offset, to: step.offset + (step.length ?? 1), kind: "cursor" });
  }

  const pushed = step.frames.length > (previous?.frames.length ?? 0);
  const popped = step.frames.length < (previous?.frames.length ?? 0);

  return (
    <div className="viz">
      <StepBar player={player} label="Sink call" />

      <StepNote op={step.call}>
        {CALL_NOTE[step.call] ?? "—"}
        {step.wrote && ` Member ${step.wrote}.`}
      </StepNote>

      <InputTape bytes={trace.bytes} marks={marks} blockSize={0} label="the document" />

      <div className="frames-split">
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
                className={cx("frame", position === 0 && "top", pushed && position === 0 && "chg")}
              >
                <code>{schema?.name ?? "?"}</code>
                <span className="frame-storage">
                  storage +{frame.storageOffset ?? "?"}
                </span>
                <span className={cx("frame-pending", frame.field && "set")}>
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
                step.text != null ? <code key="a">{JSON.stringify(step.text)}</code> : "—"
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
        {!trace.verified && <DriftedInline>The destination did not hold what the document said.</DriftedInline>}
      </p>
    </div>
  );
}

export function SchemaRoutingViz({ trace }: { trace: FrameTrace }) {
  const steps = trace.steps;
  const player = useSteps(steps.length, 900);
  const { index } = player;
  const step = steps[index];
  if (!step) return null;

  const pushesSoFar = steps
    .slice(0, index + 1)
    .filter((s) => s.call === "beginObject" || s.call === "beginArray").length;
  const live = new Map<number, number>();
  for (const frame of step.frames) live.set(frame.schema, (live.get(frame.schema) ?? 0) + 1);

  return (
    <div className="viz">
      <StepBar player={player} label="Sink call" />

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
            <div key={schema.id} className={cx("schema-card", borrows > 0 && "live")}>
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
            onClick={() => player.seek(position)}
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
