import { useState } from "react";

import type { FieldMatchTrace, FieldProbe, FieldTable } from "../types";
import type { Cell } from "./common";
import { Facts, StepBar, StepNote, VectorRow, glyph, hex, useSteps } from "./common";

// The key match, at two scales.
//
// `keyMatch` is about how a key becomes something comparable: eight bytes in one load, zero
// padded, compared as a word against the length beside it. `fieldTable` is about how the entry is
// *found* — a walk over a handful of entries, or a probe into a slot table once there are enough
// of them for the walk to stop being free.
//
// Both step over the same recorded probes, and every probe's answer was checked against the
// shipped matcher over the same table.

/** The eight lanes of a padded leading word, with the zero padding past the key's end marked. */
function wordCells(bytes: number[], wordBytes: number[]): Cell[] {
  return wordBytes.map((byte, lane) => ({
    text: hex(byte),
    sub: lane < bytes.length ? glyph(byte) : "0",
    on: lane < bytes.length,
    dim: lane >= bytes.length,
    title:
      lane < bytes.length
        ? `byte ${lane} of the key`
        : "past the key: zero, which is what makes a short key comparable as a whole word"
  }));
}

function probeOutcome(probe: FieldProbe, table: FieldTable): string {
  if (probe.shipped < 0) return "no such member";
  const entry = table.entries[probe.shipped];
  return `${entry.key} · ${entry.kind} at +${entry.offset}`;
}

/**
 * How a key is compared.
 *
 * The key's first eight bytes are one unaligned load, zero padded past its end, and the compare is
 * that word against the entry's plus a two-byte length. Nothing is hashed and nothing is
 * allocated; a key longer than a word verifies its tail only once the first word has already
 * matched, which is a call that almost never runs.
 */
export function KeyMatchViz({ trace }: { trace: FieldMatchTrace }) {
  const probes = trace.tables.flatMap((table) =>
    table.probes.map((probe) => ({ probe, table }))
  );
  const [choice, setChoice] = useState(0);
  const selected = probes[choice];
  // One step to build the word, then one per entry the matcher looked at.
  const stepCount = (selected?.probe.steps.length ?? 0) + 1;
  const { index, setIndex, playing, play } = useSteps(stepCount, 1000);
  if (!selected) return null;

  const { probe, table } = selected;
  const compare = index === 0 ? null : probe.steps[index - 1];
  const entry = compare && compare.entry >= 0 ? table.entries[compare.entry] : null;

  return (
    <div className="viz">
      <div className="chip-row">
        {probes.map(({ probe: candidate, table: from }, position) => (
          <button
            key={`${from.name}-${candidate.key}`}
            className={`chip ${position === choice ? "active" : ""}`}
            onClick={() => {
              setChoice(position);
              setIndex(0);
            }}
          >
            {JSON.stringify(candidate.key)}
            {/* The table too: both tables are probed with a key they do not have, and two chips
                reading only `"missing"` would be the same chip twice. */}
            <span style={{ color: "var(--text-muted)", marginLeft: 6 }}>
              {from.name} · {candidate.length}B
            </span>
          </button>
        ))}
      </div>

      <StepBar
        index={index}
        count={stepCount}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Compare"
      />

      <StepNote op={index === 0 ? "streamPaddedWord" : "cmp"}>
        {index === 0 ? (
          <>
            One unaligned 8-byte load, masked to the key's length. A key shorter than a word is
            zero past its end, so <em>every</em> key is one word and one length — there is no short
            case.
          </>
        ) : entry && compare ? (
          compare.hit ? (
            <>
              Entry {compare.entry} (<code>{entry.key}</code>) matches
              {compare.tailChecked ? " — first word, length, then the tail." : " on word and length."}
            </>
          ) : compare.wordEqual ? (
            <>
              Entry {compare.entry} (<code>{entry.key}</code>) has the same first word but a
              different length.
            </>
          ) : (
            <>
              Entry {compare.entry} (<code>{entry.key}</code>) differs in the first word. One
              compare settles it.
            </>
          )
        ) : (
          <>An empty bucket: nothing is stored here, so the key is not a member of this table.</>
        )}
      </StepNote>

      <div className="vec-stack">
        <VectorRow
          op="key"
          note={`${probe.length} bytes`}
          cells={Array.from({ length: 8 }, (_, lane) => ({
            text: lane < probe.bytes.length ? glyph(probe.bytes[lane]) : "",
            sub: lane < probe.bytes.length ? String(lane) : "",
            dim: lane >= probe.bytes.length
          }))}
          phase="past"
        />
        <VectorRow
          op="paddedWord"
          note="one load, masked"
          cells={wordCells(probe.bytes, probe.wordBytes)}
          phase={index === 0 ? "now" : "past"}
          epoch={choice}
        />
        <VectorRow
          op="entry"
          note={entry ? `#${compare?.entry} ${entry.key}` : "—"}
          cells={
            entry
              ? wordCells(
                  Array.from({ length: Math.min(entry.keyLength, 8) }),
                  entry.wordBytes
                ).map((cell, lane) => ({
                  ...cell,
                  sub: lane < entry.keyLength ? glyph(entry.wordBytes[lane]) : "0",
                  on: lane < entry.keyLength && entry.wordBytes[lane] === probe.wordBytes[lane],
                  changed: index > 0 && entry.wordBytes[lane] !== probe.wordBytes[lane]
                }))
              : Array.from({ length: 8 }, () => ({ text: "·", dim: true }))
          }
          phase={index === 0 ? "future" : "now"}
          epoch={index}
        />
      </div>

      <Facts
        items={[
          ["key word", <code key="w">{probe.word}</code>],
          ["key length", `${probe.length} bytes`],
          [
            "entry word",
            entry ? <code key="e">{entry.keyWord}</code> : <span key="e">—</span>
          ],
          [
            "tail",
            compare?.tailChecked ? (
              <>
                <code>streamBytesEqual</code> over bytes 8–{probe.length - 1}:{" "}
                {compare.tailEqual ? "equal" : "different"}
              </>
            ) : (
              "not read — the key fits in a word, or the first word already differed"
            )
          ],
          ["result", probeOutcome(probe, table)]
        ]}
      />

      <p className="viz-caption">
        A key never becomes a <code>String</code> and never reaches a <code>Dictionary</code>. The
        parser hands over the bytes in place; the match reads eight of them.
      </p>

      <p className="viz-note">
        A <em>dynamic</em> key — one going into a <code>StreamDictionary</code> rather than at a
        declared member — is a different question, and takes a different hash:{" "}
        <code>streamHashBytes</code> over the whole key, which for{" "}
        <code>{JSON.stringify(probe.key)}</code> is <code>{probe.bytesHash}</code>. Sixteen bytes
        per vector load into two accumulators, where the field table's{" "}
        <code>streamFieldHash</code> only has to avalanche the one word it already has.
        {!probe.verified && (
          <strong style={{ color: "var(--warning)" }}>
            {" "}
            ⚠ This walk disagreed with the shipped matcher.
          </strong>
        )}
      </p>
    </div>
  );
}

/**
 * How the entry is found.
 *
 * Below the threshold the match is a walk: a few compares against forty-byte strides the
 * prefetcher already has, which is the same compares the generated `switch` it replaced made as a
 * chain. Above it the table carries an open-addressed index and the walk becomes a probe. Both
 * tables here are real — built by the shipped `StreamFieldTable.init` — and the threshold is read
 * off the type rather than written down.
 */
export function FieldTableViz({ trace }: { trace: FieldMatchTrace }) {
  const [which, setWhich] = useState(0);
  const [probeIndex, setProbeIndex] = useState(0);
  const table = trace.tables[which];
  const probe = table?.probes[probeIndex];
  const { index, setIndex, playing, play } = useSteps(probe?.steps.length ?? 0, 900);
  if (!table || !probe) return null;

  const step = probe.steps[Math.min(index, probe.steps.length - 1)];
  const visited = new Set(probe.steps.slice(0, index + 1).map((s) => s.entry));
  const buckets = new Set(probe.steps.slice(0, index + 1).map((s) => s.bucket));

  return (
    <div className="viz">
      <div className="chip-row">
        {trace.tables.map((candidate, position) => (
          <button
            key={candidate.name}
            className={`chip ${position === which ? "active" : ""}`}
            onClick={() => {
              setWhich(position);
              setProbeIndex(0);
              setIndex(0);
            }}
          >
            {candidate.name}
            <span style={{ color: "var(--text-muted)", marginLeft: 6 }}>
              {candidate.entries.length} fields · {candidate.strategy}
            </span>
          </button>
        ))}
      </div>

      <div className="chip-row">
        {table.probes.map((candidate, position) => (
          <button
            key={candidate.key}
            className={`chip ${position === probeIndex ? "active" : ""}`}
            onClick={() => {
              setProbeIndex(position);
              setIndex(0);
            }}
          >
            {JSON.stringify(candidate.key)}
          </button>
        ))}
      </div>

      <StepBar
        index={index}
        count={probe.steps.length}
        playing={playing}
        onPlay={play}
        onSeek={setIndex}
        label="Probe"
      />

      <StepNote op={table.strategy === "indexed" ? "probe" : "scan"}>
        {table.strategy === "indexed" ? (
          step.entry < 0 ? (
            <>
              Bucket {step.bucket} is empty. The probe stops: an open-addressed miss walks to the
              first hole, which is what bounds it.
            </>
          ) : (
            <>
              Bucket {step.bucket} holds entry {step.entry}.{" "}
              {step.hit ? "It matches; the walk is over." : "It does not match; probe forward one."}
            </>
          )
        ) : (
          <>
            Entry {step.entry} of {table.entries.length}.{" "}
            {step.hit
              ? "Match."
              : step.wordEqual
                ? "Same first word, different length."
                : "Different first word — one compare."}
          </>
        )}
      </StepNote>

      {table.strategy === "indexed" && (
        <div className="slot-table">
          <div className="table-head">
            <strong>index</strong>
            <code>hash &amp; {table.slots.length - 1}</code>
          </div>
          <div className="slot-cells">
            {table.slots.map((slot, bucket) => (
              <i
                key={bucket}
                className={`slot ${slot >= 0 ? "full" : ""} ${
                  buckets.has(bucket) ? "walked" : ""
                } ${bucket === step.bucket ? "cur" : ""}`}
                title={
                  slot >= 0
                    ? `bucket ${bucket} → entry ${slot} (${table.entries[slot].key})`
                    : `bucket ${bucket}: empty`
                }
              >
                {slot >= 0 ? slot : ""}
              </i>
            ))}
          </div>
          <p className="table-note">
            {table.slots.length} buckets for {table.entries.length} entries — half load, the same
            as <code>StreamDictionary</code>'s table, because linear probing degrades sharply past
            it. Built once at construction: a field table never grows.
          </p>
        </div>
      )}

      <table className="entry-table">
        <thead>
          <tr>
            <th>#</th>
            <th>key</th>
            <th>first word</th>
            <th>len</th>
            <th>kind</th>
            <th>offset</th>
            {table.strategy === "indexed" && <th>bucket</th>}
          </tr>
        </thead>
        <tbody>
          {table.entries.map((entry) => {
            const here = step.entry === entry.index;
            return (
              <tr
                key={entry.index}
                className={`${here ? "here" : ""} ${
                  visited.has(entry.index) && !here ? "walked" : ""
                } ${!visited.has(entry.index) && !here ? "untouched" : ""}`}
              >
                <td className="mono">{entry.index}</td>
                <td className="mono">{entry.key}</td>
                <td className="mono">{entry.keyWord}</td>
                <td className="mono">{entry.keyLength}</td>
                <td>{entry.kind}</td>
                <td className="mono">+{entry.offset}</td>
                {table.strategy === "indexed" && <td className="mono">{entry.bucket}</td>}
              </tr>
            );
          })}
        </tbody>
      </table>

      <p className="viz-caption">
        {table.strategy === "scan" ? (
          <>
            {table.entries.length} fields, at or below the threshold of {table.threshold}: a scan
            costs no table at all and measures the same as a probe. {index + 1} compare
            {index === 0 ? "" : "s"} so far.
          </>
        ) : (
          <>
            {table.entries.length} fields, past the threshold of {table.threshold}: the walk no
            longer fits in what the prefetcher hides, so the table carries an index and the same
            key resolves in {probe.steps.length} probe{probe.steps.length === 1 ? "" : "s"} instead
            of a walk over {table.entries.length} entries.
          </>
        )}
      </p>

      <p className="viz-note">
        An entry is forty bytes laid out so the match reads the first sixteen — the key's first
        word and its length — and touches <code>kind</code>, <code>offset</code> and{" "}
        <code>prepare</code> only on a hit. Result:{" "}
        <code>{probeOutcome(probe, table)}</code>.
        {!trace.verified && (
          <strong style={{ color: "var(--warning)" }}>
            {" "}
            ⚠ A recorded walk disagreed with the shipped matcher.
          </strong>
        )}
      </p>
    </div>
  );
}
