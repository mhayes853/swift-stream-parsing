# Benchmarks

A separate SwiftPM package because `ordo-one/benchmark` requires a higher minimum deployment
target than `swift-stream-parsing` supports, and SwiftPM applies platform requirements
package-wide rather than per-target.

```sh
swift package --package-path Benchmarks benchmark
swift package --package-path Benchmarks benchmark list
swift package --package-path Benchmarks benchmark run --filter "Real .*" --format markdown
swift package --package-path Benchmarks --allow-writing-to-package-directory benchmark baseline update <name>
swift package --package-path Benchmarks benchmark baseline compare <name>
```

Set `STREAM_PARSING_COLLISION_REPORT=1` on `benchmark list` to replay `StreamDictionary`'s table
growth over the dynamic-key maps in CITM catalog and GSoC 2018. The report separates occupied
buckets visited while proving an insertion absent from those visited while placing entries and
rebuilding the table.

## What is measured, and what is not

Everything here runs against shipped code. Strategy comparisons that chose an implementation are
recorded in `NEW_ARCHITECTURE.md` with their tables and then deleted, because a prototype kept
past its decision drifts away from the thing it was supposed to be a control for. For example,
`NumberParseBenchmarks.swift` held six private re-implementations of the number parse, none of
which called the shipped scanners by the time it was removed, and the original key lookup suite
held six prototype tables against the one that shipped.

Not everything worth pinning is a benchmark. Nesting depth and buffer capacity are measured here
*and* pinned in `DepthLimitTests` and `BufferCapacityTests`; concurrency and malformed input are
tests only (`ConcurrentParsingTests`, `ErrorOffsetTests`, `AdversarialConformanceTests`), since
what matters about them is whether they are correct, not how fast they are wrong.

## Groups

| prefix | what it covers |
| --- | --- |
| `Fast` | the sink interface over synthetic payload shapes, bulk / 64 B / byte by byte |
| `Real` | the yyjson corpus and an LLM message, through both layers |
| `API` | `PartialsStream` views/snapshots and public async partial sequences |
| `Stream` | the convenience layer: snapshots, views, chunk sizes |
| `Scaling` | the same shape at 10 and 400 users |
| `Retention` | what holding partial states costs |
| `Dictionary` | `StreamDictionary` end to end, by key count |
| `Keys` | `StreamDictionary`'s two lookup routes in isolation |
| `Depth` | the frame spine, at 16 and 63 levels |
| `Schema` | key matching against a 48 member type |
| `Buffer` | `bufferCapacity`, and the parser's own malloc |
| `Boundary` | chunk sizes that land inside tokens rather than between them |
| `Numbers` | number token shapes through the real parser |

Payload benchmarks report both iterations per second and payload MB/s.

## Payloads

Synthetic payloads are generated in `Payloads.swift`. `Resources/` holds the real ones:
`twitter.json`, `canada.json`, `citm_catalog.json`, `gsoc-2018.json`, `github_events.json` and
`twitterescaped.json` come from
[yyjson_benchmark](https://github.com/ibireme/yyjson_benchmark/tree/master/data/json), which is
the corpus comparable parsers publish against, so these numbers can be read next to somebody
else's at the level of input shape. The numbers are not direct parser shoot-out results: the raw
rows stream events into a counting sink and the convenience rows materialize Swift partials,
whereas commonly published yyjson and simdjson results generally build or query their own data
representations.

`llm_message.json` is an assistant message of long escaped markdown, fenced code and tool-use
objects. `Payloads.swift` also generates realistic Qwen 3 structured outputs: the canonical JSON
inside small and medium `<tool_call>` elements, plus a direct structured response. These exercise
the workload the convenience layer exists for at sizes below the 1 MB stress message.
