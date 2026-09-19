import { useState } from "react";
import { cx } from "../lib/cx";
import type { CollectionTrace, StreamStringTrace, ViewTrace } from "../types";
import { Choices, Drifted, Facts, StepBar, StepNote, useSteps } from "./common";

const EVENT: Record<string, string> = {
  inline: "Inside the value. No allocation, no reference count — a copy of this string copies these bytes.",
  promote: "The inline bytes overflowed. Everything accumulated so far moves into the tail, once.",
  append: "Appended to the filling block. The only allocated storage an append can touch.",
  seal: "The tail filled: it is sealed as a block and never written again, and the next one is twice the size."
};

function SealedBlock({ position, grow, fresh, meta }: { position: number; grow: number; fresh: boolean; meta: string }) {
  return (
    <div className={cx("block sealed", fresh && "chg")} style={{ flexGrow: grow }}>
      <div className="block-track">
        <div className="block-fill" style={{ width: "100%" }} />
      </div>
      <span className="block-label">block {position}</span>
      <span className="block-meta">{meta}</span>
    </div>
  );
}

export function StreamStringViz({ trace }: { trace: StreamStringTrace }) {
  const steps = trace.steps;
  const player = useSteps(steps.length, 1000);
  const { index } = player;
  const step = steps[index];
  const previous = steps[index - 1];
  if (!step) return null;

  const scale = Math.max(
    trace.inlineCapacity,
    ...steps.flatMap((s) => [...s.blocks, s.tailCapacity])
  );
  const inline = step.blocks.length === 0 && step.tailCount === 0;

  return (
    <div className="viz">
      <StepBar player={player} label="Append" />

      <StepNote op={step.event === "inline" ? "inline bytes" : `streamAppend(utf8:)`}>
        {index === 0 ? (
          <>An empty value: {trace.inlineCapacity} bytes of inline capacity and nothing allocated.</>
        ) : (
          <>
            {step.chunkBytes} bytes in. {EVENT[step.event]}
          </>
        )}
      </StepNote>

      <div className="blocks">
        <div className={cx("block inline", inline ? "live" : "spent")} style={{ flexGrow: trace.inlineCapacity / scale }}>
          <div className="block-track">
            <div
              className="block-fill"
              style={{
                width: `${(step.inlineCount / trace.inlineCapacity) * 100}%`,
                background: "var(--series-3)"
              }}
            />
          </div>
          <span className="block-label">inline</span>
          <span className="block-meta">
            {step.inlineCount}/{trace.inlineCapacity}
          </span>
        </div>

        {step.blocks.map((capacity, position) => (
          <SealedBlock
            key={position}
            position={position}
            grow={capacity / scale}
            fresh={(previous?.blocks.length ?? 0) <= position}
            meta={`${capacity}B · sealed`}
          />
        ))}

        {!inline && (
          <div className="block tail live" style={{ flexGrow: step.tailCapacity / scale }}>
            <div className="block-track">
              <div
                className="block-fill"
                style={{
                  width: `${(step.tailCount / Math.max(step.tailCapacity, 1)) * 100}%`,
                  background: "var(--series-1)"
                }}
              />
            </div>
            <span className="block-label">tail</span>
            <span className="block-meta">
              {step.tailCount}/{step.tailCapacity}
            </span>
          </div>
        )}
      </div>

      <Facts
        items={[
          ["utf8Count", `${step.utf8Count} bytes`],
          ["allocations", `${step.blocks.length + (inline ? 0 : 1)}`],
          [
            "schedule",
            <>
              {trace.inlineCapacity} inline, then {trace.firstBlockCapacity} doubling to{" "}
              {trace.maximumBlockCapacity}
            </>
          ],
          [
            "a snapshot copies",
            inline ? "the value's own bytes" : `at most the tail — ${step.tailCount} bytes`
          ]
        ]}
      />

      <p className="viz-caption">
        {step.event === "promote" ? (
          <>
            The one copy in the whole schedule. Everything accumulated inline moves into the tail
            here and never moves again.
          </>
        ) : step.event === "seal" ? (
          <>
            A block seals at {step.blocks[step.blocks.length - 1]} bytes and the next tail starts at{" "}
            {step.tailCapacity} — double. Doubling bounds both the number of allocations and how
            much an append after a snapshot has to copy; a uniform schedule can only bound one.
          </>
        ) : (
          <>
            Blocks hold <code>ContiguousArray</code> rather than a class wrapping one: a single
            refcounted pointer each, copy-on-write for the shared tail for free, and every stored
            property stays a value type — which is what lets <code>Sendable</code> be checked
            rather than asserted.
          </>
        )}
      </p>

      {trace.locate.length > 0 && (
        <div className="locate">
          <div className="table-head">
            <strong>sealedPosition(of:)</strong>
            <code>one clz, not a search</code>
          </div>
          <div className="entry-scroll">
            <table className="entry-table">
              <thead>
                <tr>
                  <th>position</th>
                  <th>block</th>
                  <th>offset in block</th>
                  <th>byte</th>
                </tr>
              </thead>
              <tbody>
                {trace.locate.map((entry) => (
                  <tr key={entry.position}>
                    <td className="mono">{entry.position}</td>
                    <td className="mono">
                      {entry.region === "tail" ? "tail" : entry.block}
                    </td>
                    <td className="mono">{entry.offset}</td>
                    <td className="mono">{String.fromCharCode(entry.byte)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <p className="table-note">
            The schedule is a pure function of the first block's shift and the block index, so
            locating a byte inverts it in closed form — inside the doubling ramp the block index is{" "}
            <code>log2((position &gt;&gt; s) + 1)</code>, one <code>clz</code>; past the ramp it is
            a shift and a mask. A search over prefix sums is what that replaces.
          </p>
        </div>
      )}

      {!trace.verified && <Drifted>The value did not hand back the bytes it was given.</Drifted>}
    </div>
  );
}

export function CollectionsViz({ trace }: { trace: CollectionTrace }) {
  const [which, setWhich] = useState(0);
  const array = which === 0;
  const player = useSteps((array ? trace.array.steps : trace.dictionary.steps).length, 260, which);

  return (
    <div className="viz">
      <Choices
        items={["StreamArray", "StreamDictionary"]}
        selected={which}
        onSelect={setWhich}
        itemKey={(name) => name}
        label={(name) => name}
      />

      <StepBar player={player} label={array ? "Element" : "Key"} />

      {array ? (
        <ArrayPanel trace={trace} index={player.index} />
      ) : (
        <DictionaryPanel trace={trace} index={player.index} />
      )}

      {!trace.verified && <Drifted>A container did not hand back what it was given.</Drifted>}
    </div>
  );
}

function ArrayPanel({ trace, index }: { trace: CollectionTrace; index: number }) {
  const steps = trace.array.steps;
  const step = steps[Math.min(index, steps.length - 1)];
  const previous = steps[index - 1];
  if (!step) return null;
  const scale = Math.max(trace.array.blockCapacity, step.tailCapacity, 1);
  const held = steps[trace.array.snapshotAfter];
  const detached = steps.slice(0, index + 1).some((s) => s.event === "detach");

  return (
    <>
      <StepNote op={step.event === "commit" ? "drainPending" : "_openElement"}>
        {step.event === "seal" ? (
          <>
            Committing element {step.index - 1} filled the tail: the block object moves into the
            spine as a sealed block of {trace.array.blockCapacity}, and the elements do not move.
          </>
        ) : step.event === "grow" ? (
          <>
            The small first tail is full at {trace.array.initialTailCapacity}, so it is promoted to
            a full block of {step.tailCapacity} — moved when nothing else holds it, copied when
            something does. Every tail after the first sealed block starts at full size.
          </>
        ) : step.event === "commit" ? (
          <>The last element commits at the close. Nothing is open any more.</>
        ) : step.event === "detach" ? (
          <>
            Element {step.index} opens, and the snapshot taken after element{" "}
            {trace.array.snapshotAfter} still holds the block this commit was going to write into.
            So <code>nextSlot</code> finds it shared and detaches it: the {held?.tailCount ?? 0}{" "}
            initialised elements are copied into a block of this array's own, and the snapshot
            keeps the original. Both can be appended to now, and neither can see the other's slot{" "}
            {step.tailCount - 1}.
          </>
        ) : (
          <>
            Element {step.index} opens. Opening it is what committed the previous one — the open
            element lives outside the blocked storage, in <code>pending</code>, so a plain copy of
            the value diverges it for free and the parser's pointer keeps naming the parser's own
            element.
          </>
        )}
      </StepNote>

      <div className="blocks">
        {step.blocks.map((capacity, position) => (
          <SealedBlock
            key={position}
            position={position}
            grow={capacity / scale}
            fresh={(previous?.blocks.length ?? 0) <= position}
            meta={`${capacity} elements`}
          />
        ))}
        <div
          className={cx("block tail live", step.event === "grow" && "chg")}
          style={{ flexGrow: Math.max(step.tailCapacity, 8) / scale }}
        >
          <div className="block-track">
            <div
              className="block-fill"
              style={{
                width: `${(step.tailCount / Math.max(step.tailCapacity, 1)) * 100}%`,
                background: "var(--series-1)"
              }}
            />
            {step.event === "detach" && held && (
              <div
                className="block-fill shared"
                style={{
                  width: `${(held.tailCount / Math.max(step.tailCapacity, 1)) * 100}%`,
                  background: "var(--series-3)"
                }}
              />
            )}
          </div>
          <span className="block-label">{step.event === "detach" ? "tail — copied" : "tail"}</span>
          {/* A just-sealed tail has capacity 0 until the next commit reserves a block. */}
          <span className="block-meta">
            {step.tailCapacity === 0
              ? "unreserved"
              : step.event === "detach" && held
                ? `${step.tailCount}/${step.tailCapacity} — ${held.tailCount} copied out of the snapshot's`
                : `${step.tailCount}/${step.tailCapacity}`}
          </span>
        </div>
        <div className={cx("block pending", step.pending == null ? "spent" : "live")}>
          <div className="block-track">
            <div
              className="block-fill"
              style={{ width: step.pending == null ? "0%" : "100%", background: "var(--series-3)" }}
            />
          </div>
          <span className="block-label">pending</span>
          <span className="block-meta">{step.pending ?? "none"}</span>
        </div>
      </div>

      <Facts
        items={[
          ["count", String(step.count)],
          [
            "block capacity",
            `${trace.array.blockCapacity} ${trace.array.elementType}s — ${trace.array.trivialBlockCapacity} for ${trace.array.trivialElementType}`
          ],
          ["first tail reservation", `${trace.array.initialTailCapacity} — it promotes once`],
          [
            "allocations",
            // This value's own blocks. Once the tail is detached the snapshot is holding one more,
            // which is the allocation the copy cost and the reason to say so here.
            `${step.blocks.length + (step.tailCapacity > 0 ? 1 : 0)}${detached ? " — the snapshot holds one more" : ""}`
          ],
          [
            "blocks copied",
            !held ? "—" : detached ? "1 — the tail the snapshot shared" : "0 so far"
          ]
        ]}
      />

      <p className="viz-caption">
        Reads see the pending element as the last one, which is what keeps an incomplete element
        visible while it streams. The sealed count is <code>blocks.count &lt;&lt; shift</code> and
        needs no stored field, because every block is the same power of two. The power is chosen
        per element type: an element with a destroy keeps the default of{" "}
        {trace.array.blockCapacity}, while a trivial element of at most sixteen bytes aims its
        blocks at 2 KB instead — {trace.array.trivialBlockCapacity} for{" "}
        <code>{trace.array.trivialElementType}</code> — because its block has no destroy loop to
        outweigh the allocations saved. A block is a{" "}
        <code>StreamBlock</code> — a <code>ManagedBuffer</code> whose elements are tail-allocated
        with it — rather than a <code>ContiguousArray</code>, because an array never exposes its
        spare capacity: committing would mean handing the element to <code>append</code>, and a
        shared array copies all of its elements before the first of those writes. Owning the
        capacity is what keeps the copy above to the one block that was shared.
      </p>
    </>
  );
}

function DictionaryPanel({ trace, index }: { trace: CollectionTrace; index: number }) {
  const steps = trace.dictionary.steps;
  const step = steps[Math.min(index, steps.length - 1)];
  if (!step) return null;
  const indexed = step.tableCount > 0;

  return (
    <>
      <StepNote op="_openValue(forKey:initial:)">
        {step.event === "index" ? (
          <>
            Key {step.entryCount} crosses the threshold of {trace.dictionary.indexThreshold}: the
            slot table is built, {step.tableCount} buckets at half load.
          </>
        ) : (
          <>
            <code>{JSON.stringify(step.key)}</code> hashes to <code>{step.hash}</code>.{" "}
            {indexed
              ? "One probe into the slot table."
              : `A scan over ${step.entryCount - 1} entr${step.entryCount === 2 ? "y" : "ies"} — below the threshold, that measures the same as a probe and costs no table.`}
          </>
        )}
      </StepNote>

      <div className="dict-entries">
        {steps.slice(0, index + 1).map((entry, position) => (
          <span key={entry.key} className={cx("dict-entry", position === index && "cur")}>
            <em>{position}</em>
            {entry.key}
          </span>
        ))}
      </div>

      {indexed && (
        <div className="slot-table">
          <div className="table-head">
            <strong>slot table</strong>
            <code>hash &amp; {step.tableCount - 1}</code>
          </div>
          <div className="slot-cells">
            {trace.dictionary.slots.map((slot, bucket) => (
              <i
                key={bucket}
                className={cx("slot", slot >= 0 && slot <= index && "full")}
                title={
                  slot >= 0
                    ? `bucket ${bucket} → entry ${slot}`
                    : `bucket ${bucket}: empty`
                }
              >
                {slot >= 0 && slot <= index ? slot : ""}
              </i>
            ))}
          </div>
          <p className="table-note">
            Open-addressed, −1 where empty, held at half load. The entries themselves stay in
            append-only storage, which inherits the invariant the array path relies on and keeps
            insertion order, so converting to an ordered container is lossless.
          </p>
        </div>
      )}

      <Facts
        items={[
          ["entries", String(step.entryCount)],
          ["stored values", `${step.storedValueCount} — the pending one is still inline`],
          ["pendingSlot", String(step.pendingSlot)],
          ["threshold", `${trace.dictionary.indexThreshold} keys`]
        ]}
      />

      <div className="entry-scroll">
        <table className="entry-table">
          <thead>
            <tr>
              <th>lookup</th>
              <th>hash</th>
              <th>probe chain</th>
              <th>slot</th>
            </tr>
          </thead>
          <tbody>
            {trace.dictionary.lookups.map((lookup) => (
              <tr key={lookup.key} className={lookup.found ? "" : "untouched"}>
                <td className="mono">{JSON.stringify(lookup.key)}</td>
                <td className="mono">{lookup.hash}</td>
                <td className="mono">{lookup.buckets.join(" → ")}</td>
                <td className="mono">{lookup.found ? lookup.slot : "miss"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="viz-caption">
        A byte-keyed slot table rather than a <code>[String: Int]</code>: 12–17 ns per hit against
        34–42, flat in key count, and no allocation on a lookup where a <code>Dictionary</code>{" "}
        materialises a <code>String</code> for one. Deliberately collided keys degrade to the scan
        it replaces, since every step compares a <code>UInt64</code> before it compares bytes.
      </p>
    </>
  );
}

export function ViewsViz({ trace }: { trace: ViewTrace }) {
  const steps = trace.members.length + 1;
  const player = useSteps(steps, 1000);
  const { index } = player;
  const snapshot = index === trace.members.length;
  const member = snapshot ? null : trace.members[index];
  const copied = snapshot ? trace.size : (member?.size ?? 0);

  return (
    <div className="viz">
      <StepBar player={player} label="Read" />

      <StepNote op={snapshot ? "view.value" : `view.${member?.name}`}>
        {snapshot ? (
          <>
            A whole snapshot: all {trace.size} bytes of the value, copied out of the storage the
            parser is still writing to.
          </>
        ) : (
          <>
            One member. {member?.size} of {trace.size} bytes are read —{" "}
            {Math.round((copied / trace.size) * 100)}% of the value.
            {member?.indirect &&
              " Its bytes past the inline buffer live in blocks the copy shares rather than duplicates."}
          </>
        )}
      </StepNote>

      <div className="storage">
        <div className="storage-head">
          <code>{trace.typeName}</code>
          <span>
            {trace.size} bytes · stride {trace.stride}
          </span>
        </div>
        <div className="storage-row">
          {trace.members.map((entry, position) => (
            <div
              key={entry.name}
              className={cx("storage-cell", (snapshot || position === index) && "writing")}
              style={{ flexGrow: entry.size }}
              onClick={() => player.seek(position)}
              role="button"
              title={`${entry.name}: ${entry.kind}, ${entry.size} bytes at +${entry.offset}`}
            >
              <span className="storage-name">{entry.name}</span>
              <span className="storage-meta">
                +{entry.offset} · {entry.size}B
              </span>
            </div>
          ))}
        </div>
      </div>

      <Facts
        items={[
          ["read", snapshot ? "the whole value" : <code key="m">{member?.name}</code>],
          ["bytes copied", `${copied} of ${trace.size}`],
          ["value", <code key="v">{snapshot ? "…" : member?.value}</code>],
          [
            "kind",
            snapshot ? `${trace.members.length} members` : `${member?.kind}`
          ]
        ]}
      />

      <p className="viz-caption">
        {snapshot ? (
          <>
            This is what the async sequences hand over, and why they do: a view is{" "}
            <code>~Copyable</code> and <code>~Escapable</code>, so it cannot outlive the storage it
            points at, and anything that hands a value across a suspension point has to copy.
          </>
        ) : (
          <>
            The convenience layer is zero-copy by default because reading is a projection, not a
            decode: a view is a typed pointer at storage the parser owns, so a field read is a load
            at a constant offset. Snapshots are taken on demand, down to the individual member.
          </>
        )}
      </p>

      <p className="viz-note">
        The value lives in its own allocation for the whole parse, which is what lets the parser
        hold a pointer into it while a nested container streams. Nothing here relocates.
      </p>
    </div>
  );
}
