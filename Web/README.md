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
UTF-8 tables are `package` symbols read directly, and the whitespace table is reconstructed by
probing the shipped predicate over all 256 bytes. `viz` names in `pipeline.json` are validated
against the set the site knows, so a typo fails the build rather than rendering nothing.

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

## Adding a step, or attaching a new experiment

1. Write the experiment in `NEW_ARCHITECTURE.md` as usual. Put the verdict in the heading
   (`Landed: …` / `Rejected: …`) so the extractor classifies it.
2. Add its section path to the relevant node's `evidence.doc` in `pipeline.json`. The path is
   `chapter-slug/section-slug`, scoped rather than document-global so that inserting a section
   elsewhere never renumbers it.
3. Run `./Web/generate`. Commit `Web/generated/`.

## Traces

The four animations replay the **shipped kernels**. `Sources/StreamParsingSiteTool/Trace` calls
`streamStringRun`, `streamWhitespaceEnd`, `streamNumberRunEnd` and `streamShortInteger` directly,
and drives a real `JSONParser` through a recording sink for the container register.

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
