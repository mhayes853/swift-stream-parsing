import { useState } from "react";

import type { CollectionTrace, StreamStringTrace, ViewTrace } from "../types";
import { Facts, StepBar, StepNote, useSteps } from "./common";

// Storage: what these values look like while they fill.
//
// Every number below was read off a real value after a real append — the block capacities, the
// tail's reservation, the slot table, the threshold each type switches strategy at. Where a
// constant could have been written down here it is read off the shipped type instead, so editing
// it in the parser moves the animation with it.

const EVENT: Record<string, string> = {
  inline: "Inside the value. No allocation, no reference count — a copy of this string copies these bytes.",
  promote: "The inline bytes overflowed. Everything accumulated so far moves into the tail, once.",
  append: "Appended to the filling block. The only allocated storage an append can touch.",
  seal: "The tail filled: it is sealed as a block and never written again, and the next one is twice the size."
};

/**
 * `StreamString` filling.
 *
 * Up to 64 bytes live in the value itself. Past that the bytes move into a tail that seals into
 * blocks, and the blocks double — which is what keeps the number of allocations logarithmic in the
 * length while bounding how much a snapshot-sharing append has to copy. A sealed block is never
 * written again, so a snapshot shares it forever.
 */
export function StreamStringViz({ trace }: { trace: StreamStringTrace }) {
  const steps = trace.steps;
  const { index, setIndex, playing, play } = useSteps(steps.length, 1000);
  const step = steps[index];
  const previous = steps[index - 1];
  if (!step) return null;

  // Blocks are drawn to scale against the largest thing on screen, because the doubling is the
  // point: a schedule drawn with equal boxes is a schedule you cannot see.
  const scale = Math.max(
    trace.inlineCapacity,
    ...steps.flatMap((s) => [...s.blocks, s.tailCapacity])
  );
  const inline = step.blocks.length === 0 && step.tailCount === 0;

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={steps.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Append"
      />

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
        <div className={`block inline ${inline ? "live" : "spent"}`} style={{ flexGrow: trace.inlineCapacity / scale }}>
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
          <div
            key={position}
            className={`block sealed ${
              (previous?.blocks.length ?? 0) <= position ? "chg" : ""
            }`}
            style={{ flexGrow: capacity / scale }}
          >
            <div className="block-track">
              <div className="block-fill" style={{ width: "100%" }} />
            </div>
            <span className="block-label">block {position}</span>
            <span className="block-meta">{capacity}B · sealed</span>
          </div>
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
          <p className="table-note">
            The schedule is a pure function of the first block's shift and the block index, so
            locating a byte inverts it in closed form — inside the doubling ramp the block index is{" "}
            <code>log2((position &gt;&gt; s) + 1)</code>, one <code>clz</code>; past the ramp it is
            a shift and a mask. A search over prefix sums is what that replaces.
          </p>
        </div>
      )}

      {!trace.verified && (
        <p className="viz-note" style={{ color: "var(--warning)" }}>
          ⚠ The value did not hand back the bytes it was given.
        </p>
      )}
    </div>
  );
}

/**
 * `StreamArray` and `StreamDictionary`.
 *
 * Two containers with the same requirement — the parser holds a pointer into them while a value
 * streams in, so nothing may relocate — and two different answers, because they are measured
 * differently. Blocking the array's storage is free; blocking the dictionary's cost 2×, because a
 * dictionary reads its storage back on every lookup where an array never reads at all.
 */
export function CollectionsViz({ trace }: { trace: CollectionTrace }) {
  const [which, setWhich] = useState<"array" | "dictionary">("array");
  const steps =
    which === "array" ? trace.array.steps : trace.dictionary.steps;
  const { index, setIndex, playing, play } = useSteps(steps.length, 260);

  return (
    <div className="viz">
      <div className="chip-row">
        <button
          className={`chip ${which === "array" ? "active" : ""}`}
          onClick={() => {
            setWhich("array");
            setIndex(0);
          }}
        >
          StreamArray
        </button>
        <button
          className={`chip ${which === "dictionary" ? "active" : ""}`}
          onClick={() => {
            setWhich("dictionary");
            setIndex(0);
          }}
        >
          StreamDictionary
        </button>
      </div>

      <StepBar
        index={index}
        count={steps.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label={which === "array" ? "Element" : "Key"}
      />

      {which === "array" ? (
        <ArrayPanel trace={trace} index={index} />
      ) : (
        <DictionaryPanel trace={trace} index={index} />
      )}

      {!trace.verified && (
        <p className="viz-note" style={{ color: "var(--warning)" }}>
          ⚠ A container did not hand back what it was given.
        </p>
      )}
    </div>
  );
}

function ArrayPanel({ trace, index }: { trace: CollectionTrace; index: number }) {
  const steps = trace.array.steps;
  const step = steps[Math.min(index, steps.length - 1)];
  const previous = steps[index - 1];
  if (!step) return null;
  const scale = Math.max(trace.array.blockCapacity, step.tailCapacity, 1);

  return (
    <>
      <StepNote op={step.event === "commit" ? "drainPending" : "_openElement"}>
        {step.event === "seal" ? (
          <>
            Committing element {step.index - 1} filled the tail: it seals as a block of{" "}
            {trace.array.blockCapacity} and is never written again.
          </>
        ) : step.event === "commit" ? (
          <>The last element commits at the close. Nothing is open any more.</>
        ) : (
          <>
            Element {step.index} opens. Opening it is what committed the previous one — the open
            element lives outside the blocked storage, so a write through the parser's pointer is
            an ordinary mutation rather than a raw write into a buffer a kept snapshot is sharing.
          </>
        )}
      </StepNote>

      <div className="blocks">
        {step.blocks.map((capacity, position) => (
          <div
            key={position}
            className={`block sealed ${(previous?.blocks.length ?? 0) <= position ? "chg" : ""}`}
            style={{ flexGrow: capacity / scale }}
          >
            <div className="block-track">
              <div className="block-fill" style={{ width: "100%" }} />
            </div>
            <span className="block-label">block {position}</span>
            <span className="block-meta">{capacity} elements</span>
          </div>
        ))}
        <div className="block tail live" style={{ flexGrow: Math.max(step.tailCapacity, 8) / scale }}>
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
          {/* A tail that has just sealed holds a fresh, unreserved buffer: its capacity really is
              zero until the next commit reserves the block. Say that rather than print `0/0`. */}
          <span className="block-meta">
            {step.tailCapacity === 0 ? "unreserved" : `${step.tailCount}/${step.tailCapacity}`}
          </span>
        </div>
        <div className={`block pending ${step.pending === null || step.pending === undefined ? "spent" : "live"}`}>
          <div className="block-track">
            <div
              className="block-fill"
              style={{
                width: step.pending === null || step.pending === undefined ? "0%" : "100%",
                background: "var(--series-3)"
              }}
            />
          </div>
          <span className="block-label">pending</span>
          <span className="block-meta">
            {step.pending === null || step.pending === undefined ? "none" : step.pending}
          </span>
        </div>
      </div>

      <Facts
        items={[
          ["count", String(step.count)],
          ["block capacity", `${trace.array.blockCapacity} elements`],
          ["first tail reservation", `${trace.array.initialTailCapacity} — it promotes once`],
          ["allocations", String(step.blocks.length + (step.tailCapacity > 0 ? 1 : 0))]
        ]}
      />

      <p className="viz-caption">
        Reads see the pending element as the last one, which is what keeps an incomplete element
        visible while it streams. The sealed count is <code>blocks.count &lt;&lt; shift</code> and
        needs no stored field, because every block is the same power of two — the array's storage
        is never read during a parse, so it has no reason to be anything else.
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
          <span key={entry.key} className={`dict-entry ${position === index ? "cur" : ""}`}>
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
                className={`slot ${slot >= 0 && slot <= index ? "full" : ""}`}
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

      <p className="viz-caption">
        A byte-keyed slot table rather than a <code>[String: Int]</code>: 12–17 ns per hit against
        34–42, flat in key count, and no allocation on a lookup where a <code>Dictionary</code>{" "}
        materialises a <code>String</code> for one. Deliberately collided keys degrade to the scan
        it replaces, since every step compares a <code>UInt64</code> before it compares bytes.
      </p>
    </>
  );
}

/**
 * Reading a value that is still being parsed.
 *
 * A view is a pointer at the storage the parser is writing through, so reading one member copies
 * that member and nothing else. A snapshot copies the value. The offsets below are the schema's
 * own field offsets and the sizes are `MemoryLayout`'s, both from the same parse the frame
 * animation steps through.
 */
export function ViewsViz({ trace }: { trace: ViewTrace }) {
  // One step per member, then the snapshot.
  const steps = trace.members.length + 1;
  const { index, setIndex, playing, play } = useSteps(steps, 1000);
  const snapshot = index === trace.members.length;
  const member = snapshot ? null : trace.members[index];
  const copied = snapshot ? trace.size : (member?.size ?? 0);

  return (
    <div className="viz">
      <StepBar
        index={index}
        count={steps}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Read"
      />

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
              className={`storage-cell ${
                snapshot || position === index ? "writing" : ""
              }`}
              style={{ flexGrow: entry.size }}
              onClick={() => setIndex(position)}
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
