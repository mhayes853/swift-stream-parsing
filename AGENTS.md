# Swift Stream Parsing
You are working on Swift Stream Parsing, a blazingly fast and convenient library for parsing JSON (or any format in the future) incrementally by streaming observable values from incomplete payloads. This library exist because certain problems require structured observable parsing (eg. structured output streaming from LLMs) when full JSON payloads are pending or are otherwise incomplete. 

`Decodable` and `JSONDecoder` do not work in these scenarios because they require the full output to be present, which may be expensive or impossible. 

Traditional SAX parsers also fail here, because they generally only emit completed values where as we want to emit updates down to the byte level. Furthermore, such parsers often lack a typed convenience layer. Though this library can also be used like traditional SAX parser in (mostly) pure Swift if desired.

## Basic Rules

We MUST run performance benchmarks (especially throughput) on the real world data sets after every change. Even subtle changes to a tiny number of lines of code can have a negative impact depending on how the Swift compiler handles optimizing, inlining, layout, etc. Furthermore, microbenchmarks on a single function do not guarantee E2E performance gains (and may even be losses!).

Right now, we're primarily focused on ARM for optimizations, but the parser also works on x86 and other architectures that support Swift (just a bit slower).

Some operations are better expressed in C than in Swift due to either incompatabilities (eg. Unrepresentable SIMD instructions) or data layout issues (eg. Pow 10 table for Eisel-Lemire fast float). `StreamParsingShims` is the target for that.

Perform rigourous analysis on the underlying assembly whenever you make a change to a critical parsing component, and surface those in your communications. (Also note that lower instruction count != faster code.)

Feel free to use whatever advanced features (including underscored attributes) in Swift that you need to achieve maximum performance.

Liberal comments are fine here, especially if readability must be sacrified in exchange for performance.

We have dedicated data types for streaming collections which includes dictionaries, arrays, and strings. These types prioritize speed whilst trying to keep a semblance of convenience.

The convenience layer is zero-copy by default as one can produce snapshots of the parsed data on-demand (down to the individual field level). However, various convenience APIs (such as the async sequences) will generally take a full snapshot of the value. This is because each parseable type is required to have a `~Copyable` and `~Escapable` view associated type, which generally is a container for a typed unsafe pointer to the value.

We rely on SIMD heavily to scan and process multiple bytes at a time using various known algorithms. In some cases where we don't have enough data to fill a full SIMD register, SWAR can be faster. Make sure to always benchmark SIMD vs SWAR if you consider using either approach.

## The algorithm explorer

`Web/` holds the algorithm explorer: a flow chart of the parse path where every node links to the
evidence behind it. It is a *view* over the material that already exists — it never becomes a
second place to keep prose.

**Every change that adds or revises evidence must update the explorer in the same commit.** That
means a new experiment (landed *or* rejected), a revised measurement table, a renamed or deleted
kernel, or a new explanation in a source comment.

How the content is sourced, and therefore what you have to touch:

- **Prose and measurements stay in `NEW_ARCHITECTURE.md` and in source comments.** These are the
  source of truth. `Sources/StreamParsingSiteTool` extracts them into `Web/generated/content.json`
  by heading slug and by declaration name. Adding a section to the doc needs no explorer change
  beyond pointing at it.
- **`Web/content/pipeline.json` is the only hand-authored file in the explorer.** It holds the
  node graph (including `next`, which is what the flow chart draws), the short prose per node, and
  the *references* — doc slugs, `File.swift:symbol` pairs, assembly symbols. A new experiment
  attaches to the node it belongs to by adding its slug to that node's evidence list.
- **Every arrow says what it is.** An edge in `next` is
  `{ to, kind, label, when }`. `label` is drawn on the arrow and is **required** — the extractor
  fails on an empty one, because an unlabelled arrow between two functions asserts only that one
  reaches the other, which is the least interesting thing about it. `kind` is `step` (runs
  unconditionally), `branch` (taken only when `when` holds), `return` (hands control back), or
  `detail` (zooms into the same work); the chart draws each differently. A node that fans out also
  carries `invokes` — one sentence on the mechanism, the `switch` or the loop — and `ordering`:
  `ordered` when `next` is written in the order the source runs or tests them, in which case the
  arrows are numbered, or `unordered` when there is no order to claim. Reordering `next` therefore
  changes what the chart asserts; keep it matching the source.
- **Keep the prose descriptive.** This is a tool for reading the parser, not a pitch for it. State
  what a step does and what was measured; drop the adjectives.
- **Rejected experiments matter as much as landed ones.** They are the reason a decision does not
  get re-litigated, and the explorer surfaces them in a dedicated graveyard view. Record the
  verdict in the section title (`Landed: …` / `Rejected: …`) so the extractor can classify it.

After changing the doc, a kernel, or `pipeline.json`:

```sh
./Web/generate            # re-extracts content.json, traces.json, and the assembly snapshots
```

Generated artifacts under `Web/generated/` are committed, so the site builds without a Swift
toolchain and evidence changes show up in diffs. The extractor **fails on a dangling reference** —
a doc slug that no longer resolves, or a symbol that was renamed or deleted — so renaming a kernel
without updating `pipeline.json` breaks the build rather than silently rotting the site.

Traces are recorded by running the *shipped* kernels (`Sources/StreamParsingSiteTool/Trace`), not by
reimplementing them, so the animations cannot drift from the parser. A kernel whose signature
changes needs its recorder updated alongside it.

Where a kernel's intermediates are not observable from outside it, the recorder mirrors the body
using the same `package` primitives and asserts its answer against the real function's; `verified`
carries that into the bundle, and `./Web/generate traces` fails if any mirror disagrees. **A lookup
table is recovered, never copied.** The number-class and UTF-8 tables are already `package` symbols
and are read directly; the whitespace table is a literal inside `streamWhitespaceMissMask`, so the
recorder probes the shipped predicate over all 256 bytes and reconstructs it — a table edited in the
parser then shows up in the explorer with nobody having to remember it.

The whitespace table is recovered this way because it is a literal inside
`streamWhitespaceMissMask`; the escape map is recovered by probing `streamDecodeSimpleEscape` at
all 128 indices, so the eight non-zero cells the site draws are the table rather than a claim about
it.

Past the vector kernels the subject changes, and so does the technique. `sink-protocol` onwards is
not a kernel with intermediates to mirror but a protocol boundary, a frame stack and storage that
grows — all of which are *stored state on shipped types*. Those recorders therefore
`@testable import StreamParsingCore` and read the real fields: `PartialSink.frames` after every
call the parser makes, `StreamString.blocks` after every append, the `StreamFieldTable` a real
`StreamSchema` built. That is stronger than a mirror, not weaker, and it costs the parser nothing:
`@testable` needs only the `-enable-testing` that SwiftPM already passes in debug, which is what
`./Web/generate` builds, and no library source changes to allow it.

The same rule about copied constants applies and is easier to keep here: the inline capacity, the
block schedule, `StreamFieldTable.indexThreshold`, `StreamDictionary.indexThreshold` and the field
offsets are all read off the shipped types, so editing one in the parser moves the animation with
it. Where a walk *is* mirrored — `consumeSkipRun`, whose cursor is not observable — it calls the
same `package` scanners the shipped loop calls and is then checked against `consumeSkipRun` itself
run over the same bytes from the same state.

These traces carry their own verification into the bundle on the same footing as a kernel mirror,
and `./Web/generate traces` fails without it: every span the parser handed over covers the bytes
its call reports; the skipping run is a subsequence of the streaming one and its container opens
and closes still balance; the mirrored skip walk and `consumeSkipRun` end on the same cursor; every
key match agrees with `streamMatchField` / `streamMatchFieldIndexed`; the frame recording's parse
produced the value the document described; and each container handed back what it was given.

Vector kernels are drawn as registers, not as coloured text: one `VectorRow` per 128-bit value,
lanes aligned in columns so a value only moves down, and the operation between rows named for the
instruction it is (`cmeq`, `tbl`, `orr`, `eor`). If a step in a kernel is a real instruction, it
should be a row.

**A visual steps through the kernel one instruction at a time, and every step says what changed.**
A stack drawn all at once shows the answer but not the work, so a row carries a `phase`: `future`
keeps its box and draws nothing (the stack must not reflow as the animation runs), `now` deals its
lanes in left to right, `past` is already computed. Where a register is *updated* rather than
produced — `scanned |= block`, the SWAR word under the mask and the bias — pass `changed` and the
altered lanes pulse instead; a row whose contents change between steps also needs `epoch`, or React
reuses the nodes and the change happens invisibly. Each step names itself in a `StepNote` under the
controls, because "what changed" has to be readable and not only visible.

**Every step also marks what it is touching in the input.** `InputTape` draws the sample's bytes
once and takes `TapeMark`s over it: `done` behind the cursor, `window` for the bytes in the
register, `cursor` for the byte the step resolves to, `next` for where the parser resumes. A rule
every sixteen bytes makes the vector boundary visible without counting. This is the reason the
container trace records `offset`/`length` per token — those come from the spans the parser hands
the sink, cross-checked against a cursor that skips whitespace with the shipped `streamWhitespaceEnd`
and steps over one separator. `offsetsVerified` carries that agreement into the bundle and
`./Web/generate traces` fails without it, on the same footing as a drifted kernel mirror.

A call log, a frame stack and a block schedule are not registers, so they are not drawn as ones —
but they take the same three phases, for the same reason: a list drawn all at once shows the answer
and not the work. `phaseOf` gives a row `past`, `now` or `future`, and a `future` row keeps its box
and shows nothing so nothing reflows mid-animation. Two places extend that rather than repeat it. A
call the skipping sink never received stays in place, struck through at low opacity, because "it
did not happen" is the thing being shown and removing the row would only misalign the columns. And
blocked storage is drawn *to scale*: a doubling schedule drawn with equal boxes is a schedule you
cannot see, so the bars are sized against the largest allocation on screen.

Motion degrades under `prefers-reduced-motion` to an instant state change rather than being removed:
the phases still differ, they simply stop animating between them.

**Every node's detail panel draws its own flow chart.** The pipeline graph says which functions
reach which; `steps` on a node says what the one function *does*, and it is the only place a branch
*inside* a kernel is written down. `AlgorithmChart` draws it in the same language as the page chart
— the same four `kind`s, the same dashing, every arrow carrying its label, ordered fan-outs
numbered — because they are the same claim at two scales, and a second notation would make that
harder to see rather than easier. The shared geometry lives in `Web/src/components/graph.ts`;
neither chart owns it.

The extractor holds a step graph to the pipeline graph's standard and then some. A node without one
is a build error, so "this step has no chart" cannot happen quietly. So are a duplicate step id, an
arrow into nothing, a step the entry cannot reach, and a graph with **no step that ends it** — that
last one matters because most of these kernels are loops, and a loop drawn with no exit is a claim
about the code that is not true of any of them. A step's `source` must resolve *and* be one the node
already lists as evidence, so following a step into the Source tab lands on a declaration that is
actually there.

These graphs have loops in them, which is why row assignment is not a plain longest path:
`rankGraph` finds the back edges by DFS first and ranks over what is left, so a loop's head sits
above its body and the returning arrow reads as a return. Two returns between the same pair of rows
would otherwise draw the same curve, so each gets its own bow. The chart is laid out twice — the
first pass measures how far a loop-back label bows past the leftmost node, the second gives the node
grid that much less — and the last few percent is taken by scaling rather than by scrolling the
panel sideways.


