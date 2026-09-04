# The algorithm explorer

A flow chart of the parse path, where every node links to the evidence behind it. It is a **view**
over material that already exists — never a second place to keep prose.

Nodes are laid out in stage rows and connected by their `next` edges, return paths included (the
whitespace scan goes back to the structural run, which calls it again before the next structural
byte). Every arrow carries its label — a verb phrase, or the condition under which it is taken.
Hovering a node opens a card describing how it reaches what it calls; selecting one opens its
animation, prose, experiments, source and assembly.

```sh
./Web/generate          # rebuild content.json, traces.json and the assembly snapshots
cd Web && npm install && npm run dev
```

## The animations

Nine nodes carry one. They are drawn from `Web/generated/traces.json`, which is produced by running
the shipped kernels — never by reimplementing them — and every mirrored intermediate is asserted
against the real function's answer before it is written.

| Node | Shows |
| --- | --- |
| `streamStringRun` | the vector pipeline: load, three splatted constants, three `cmeq`/`cmlo` masks, the `orr` fold |
| Finding the lane | `streamFirstHitLane` — mask bytes to two words to a lane index, both spellings |
| The run scan | `streamWhitespaceMissMask` — one `tbl` where the portable path ORs four compares |
| The greedy scan | `streamNumberRunEnd` — two nibble lookups and `vtstq_u8` instead of six compares |
| UTF-8 validation | three tables ANDed, then the structural fact XORed in |
| Escapes | the 128-byte simple-escape map, and why its zero is the validity test |
| One compare, then out of line | the branch, plus the 64-bit whitespace bitmap |
| The structural run | container bits |
| Eight bytes, backwards | the SWAR digit fold |

A lookup table is *recovered* from the kernel, not copied into the recorder: the number-class and
UTF-8 tables are `package` symbols read directly, the whitespace table is reconstructed by probing
the shipped predicate over all 256 bytes, and the escape map by probing the shipped decoder at all
128 indices. `viz` names in `pipeline.json` are validated against the set the site knows, so a typo
fails the build rather than rendering nothing.

### Stepping and the input tape

Every one of them steps **one instruction at a time**, and every step says what it changed. A
register row carries a `phase`:

- `future` — not computed yet. It keeps its box and draws nothing, so the stack does not reflow as
  the animation runs.
- `now` — produced by this step. Its lanes deal in left to right, which is the only motion in the
  visual and therefore reads as the change.
- `past` — already computed, drawn plainly.

Where a register is *updated* rather than produced — `scanned |= block`, or the SWAR word as the
mask and the bias run over it — pass `changed` and the altered lanes pulse instead. Such a row also
needs `epoch`, or React reuses the DOM nodes and the change happens with no animation at all. The
step names itself in a `StepNote` under the controls: "what changed" has to be readable, not only
visible.

`InputTape` draws the sample's bytes once and marks what the current step is touching — `done`
behind the cursor, `window` for the bytes in the register, `cursor` for the byte the step resolves
to, `next` for where the parser resumes — with a rule every sixteen bytes so the vector boundary is
visible without counting. The container trace therefore records a byte range per token: taken from
the spans the parser hands the sink, cross-checked against a cursor that skips whitespace with the
shipped `streamWhitespaceEnd` and steps over one separator. `offsetsVerified` carries that agreement
into the bundle and generation fails without it.

Under `prefers-reduced-motion` the phases still differ; they simply stop animating between them.

## Where things come from

| What | Lives in | Written by |
| --- | --- | --- |
| Prose, measurements, verdicts | `NEW_ARCHITECTURE.md` | you, as you work |
| Why a kernel is shaped that way | the source comments | you, as you work |
| Node graph, teaching prose, evidence references | `Web/content/pipeline.json` | **hand-authored** |
| `content.json`, `sources.json`, `traces.json`, `asm/*.txt` | `Web/generated/` | `./Web/generate` |

`pipeline.json` is the only hand-authored file. It holds the architectural ordering the document
does not have — the log is ordered by *when things were tried* — the `next` edges the chart draws,
a paragraph or two per step, and the *references*: doc section paths, `File.swift:symbol` pairs,
assembly symbols.

## Edges

An entry in `next` is `{ to, kind, label, when }`:

| Field | Meaning |
| --- | --- |
| `to` | target node id |
| `kind` | `step` runs unconditionally · `branch` is taken only when `when` holds · `return` hands control back · `detail` zooms into the same work |
| `label` | drawn on the arrow. **Required** — an empty one fails the build |
| `when` | the full circumstance, shown on the hover card |

A node that fans out also carries `invokes` (one sentence on the mechanism — the `switch` it
dispatches through, the loop it stays inside) and `ordering`. `ordering: "ordered"` means `next` is
written in the order the source runs or tests them and the chart numbers the arrows;
`"unordered"` means there is no order to claim, as with protocol methods. So reordering `next`
changes what the chart asserts — `parseDispatching`'s four arrows are numbered because they are the
arms of a `switch` in the order they are written, and `StreamParseSink`'s three are not.

Labels are placed by a de-collision pass that slides each along its own curve before nudging it
vertically, and the node boxes are seeded into the same occupancy map, so a label lands neither on
another label nor on a node.

The hover card lives in a reserved rail to the right of the graph — a column nothing is ever drawn
into — and a dashed leader connects it back to its node. A card floating over the graph hid the node
it was opened from, which is the one node the reader is looking at.

**The horizontal geometry is computed, not fixed.** `layoutFor` reads the width `.flow-scroll`
actually has (padding excluded, via a `ResizeObserver`), takes the rail off the top, then the lane
gutter, and lets the node width absorb what is left. A hard-coded width is a promise the page cannot
keep — narrowing the constants until the chart fit at one viewport just moved the overflow to the
next one. Below roughly 1050px the node width hits its floor and the chart scrolls sideways, which
is the intended degradation rather than an unreadable squeeze.

**The extractor fails the build on a dangling reference.** Rename a kernel or retitle a chapter
without updating `pipeline.json` and `./Web/generate content` exits non-zero with the closest
surviving match, rather than leaving a node in the UI pointing at nothing.

## The algorithm chart

Every node's Explanation tab opens with a flow chart of the node's own control flow, drawn above the
animation: the shape of the thing, then one run through it. It comes from `steps` on the node —
`{ id, title, kicker, detail, source, ordering, next }`, where `next` is the same edge shape as the
pipeline graph's and the first entry is the entry point.

It is deliberately the same drawing language as the page chart: the same four `kind`s, the same
dashing, every arrow carrying its label, ordered fan-outs numbered. The pipeline graph says which
functions reach which; this says what one of them does, and it is the only place a branch *inside*
a kernel is written down. The geometry both charts share lives in `src/components/graph.ts` rather
than in either of them.

What the extractor enforces, beyond the arrow rules above:

| Rule | Why |
| --- | --- |
| Every node has a `steps` graph, of at least two steps | "This step has no chart" should not be able to happen quietly |
| Step ids are unique and every `to` resolves within the node | An arrow into nothing |
| Every step is reachable from the first | A step nobody reaches is a claim the chart cannot draw |
| At least one step has an empty `next` | Most of these kernels are loops, and a loop with no exit is a claim about the code that is not true of any of them |
| A step's `source` resolves **and** is in the node's own `evidence.source` | So following a step into the Source tab lands on a declaration that is actually listed there |

Layout has to cope with loops, which a longest-path rank cannot: `rankGraph` finds the back edges by
DFS first and ranks over what is left, so a loop's head sits above its body and the returning arrow
reads as a return. Two returns between the same pair of rows would draw the same curve, so each gets
its own bow. The chart is then laid out twice — the first pass measures how far a loop-back label
bows past the leftmost node and the second gives the node grid that much less — and the last few
percent is taken by scaling the drawing rather than by scrolling the panel sideways. A step title
that cannot wrap (`StreamStringRun(end:containsNonASCII:)` has nowhere to break) is set smaller
rather than truncated, because a cut-off symbol reads as a *different* symbol.

## Adding a step, or attaching a new experiment

1. Write the experiment in `NEW_ARCHITECTURE.md` as usual. Put the verdict in the heading
   (`Landed: …` / `Rejected: …`) so the extractor classifies it.
2. Add its section path to the relevant node's `evidence.doc` in `pipeline.json`. The path is
   `chapter-slug/section-slug`, scoped rather than document-global so that inserting a section
   elsewhere never renumbers it.
3. If it changed the node's control flow, update that node's `steps` in the same edit — a new
   branch, a step that stopped existing, a `source` that moved.
4. Run `./Web/generate`. Commit `Web/generated/`.

## Traces

The animations replay the **shipped kernels**. `Sources/StreamParsingSiteTool/Trace` calls
`streamStringRun`, `streamWhitespaceEnd`, `streamNumberRunEnd`, `streamShortInteger`,
`streamIsWhitespace` and `streamDecodeSimpleEscape` directly, and drives a real `JSONParser` through
a recording sink for the container register — a sink that also resolves each `Span` it is handed
back to an offset in the buffer that was parsed, which is where the tape's token positions come
from.

That target has to live in the root package rather than beside this directory: `package` access
does not cross a SwiftPM package boundary, which is the same reason nothing in the separate
`Benchmarks` package touches those kernels either.

Where a kernel's intermediate values are not observable from outside it — per-block masks, the SWAR
words — the recorder mirrors the body using the same primitives and then **asserts the mirror
against the real function's answer**. A disagreement fails generation rather than quietly animating
something the parser does not do.

## Assembly

Pinned from the **release benchmark binary**, because that is the build where a concrete sink
specializes the generics; the doc's own figures (`parse` at 1284 bytes, `consumeStructural` at
1044) describe those specializations. Regenerate with:

```sh
./Benchmarks/bench build     # once, or after a code change
./Web/generate asm
```

Symbols are matched on length-prefixed mangled identifiers, so `consumeStructural` never resolves
to `consumeStructuralRun`, and dotted references (`JSONParser.parse`) keep `parse` off the
statically linked `ArgumentParser.LenientParser.parse`.

## Serving it

The build is **position independent**. `base` is relative and every runtime fetch resolves against
`document.baseURI`, so the same `dist/` works from a GitHub Pages subpath, from the root of any
static host, and from a local file server. A hard-coded absolute base bakes one deployment path
into the HTML and 404s the JS and all four generated bundles everywhere else, which is exactly the
failure it looks like a content problem.

```sh
cd Web && npm run build && (cd dist && python3 -m http.server 8000)
```

## Colour

The palette is the validated default from the `dataviz` reference instance. Categorical slots 1–3
carry the three string-run terminator classes and clear the all-pairs CVD and normal-vision floors
in both modes; light-mode aqua sits at 2.74:1 against the surface, below the 3:1 gate, so every
lane using it also carries a visible glyph and index. Verdicts use the fixed status palette and are
always paired with a written word — hue never carries the meaning alone. Deltas are diverging
(blue/red around a neutral midpoint) with the sign and an arrow printed beside every bar.
