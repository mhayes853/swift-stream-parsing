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
