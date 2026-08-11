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
