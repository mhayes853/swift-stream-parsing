// swift-tools-version: 6.2

import PackageDescription

// The benchmark suite lives in its own package because `ordo-one/benchmark` requires a
// higher minimum deployment target than `swift-stream-parsing` itself supports, and SwiftPM
// applies platform requirements package-wide rather than per-target.
let package = Package(
  name: "swift-stream-parsing-benchmarks",
  platforms: [.macOS(.v14)],
  dependencies: [
    // Named explicitly: a path dependency's identity defaults to its directory name, which
    // breaks the build from a git worktree whose directory is not called swift-stream-parsing.
    .package(name: "swift-stream-parsing", path: ".."),
    .package(url: "https://github.com/ordo-one/benchmark", from: "1.36.0"),
    .package(url: "https://github.com/mattt/swift-yyjson.git", from: "0.6.0")
  ],
  targets: [
    .executableTarget(
      name: "StreamParsingBenchmarks",
      dependencies: [
        .product(name: "StreamParsing", package: "swift-stream-parsing"),
        .product(name: "StreamParsingCore", package: "swift-stream-parsing"),
        .product(name: "Benchmark", package: "benchmark"),
        .product(name: "YYJSON", package: "swift-yyjson")
      ],
      path: "StreamParsingBenchmarks",
      resources: [.copy("Resources")],
      swiftSettings: [
        .define("STREAM_PARSING_BENCHMARKS"),
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("AddressableTypes")
      ],
      plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
    )
  ],
  swiftLanguageModes: [.v6]
)
