# Benchmarks

A separate SwiftPM package because `ordo-one/benchmark` requires a higher minimum deployment
target than `swift-stream-parsing` supports, and SwiftPM applies platform requirements
package-wide rather than per-target.

```sh
swift package --package-path Benchmarks benchmark
swift package --package-path Benchmarks --allow-writing-to-package-directory benchmark baseline update <name>
swift package --package-path Benchmarks benchmark baseline compare <name>
```

Handler registration is measured on its own because every parse benchmark pays for it once,
which otherwise dominates the smaller payloads. The `unhandled` variant parses a payload into
a type whose keys never match, isolating the parser state machine from value accumulation.

The suite also includes the 631 KB `twitter.json` payload from [yyjson_benchmark](https://github.com/ibireme/yyjson_benchmark/blob/master/data/json/twitter.json). Fast-parser payload benchmarks report both iterations per second and payload MB/s for bulk, 64-byte chunk, and byte-at-a-time parsing.
