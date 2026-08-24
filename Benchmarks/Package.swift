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
    .package(url: "https://github.com/ordo-one/benchmark", from: "1.36.0")
  ],
  targets: [
    // Prototype C kernels for the stage-1 extraction experiments. Lives here rather than in
    // StreamParsingShims because nothing in it ships; -O2 is forced so the kernels are
    // optimized even if the plugin ever builds debug.
    .target(
      name: "StageOneLab",
      path: "StageOneLab",
      cSettings: [.unsafeFlags(["-O2"])]
    ),
    .executableTarget(
      name: "StreamParsingBenchmarks",
      dependencies: [
        "StageOneLab",
        .product(name: "StreamParsing", package: "swift-stream-parsing"),
        .product(name: "StreamParsingCore", package: "swift-stream-parsing"),
        .product(name: "Benchmark", package: "benchmark")
      ],
      path: "StreamParsingBenchmarks",
      resources: [.copy("Resources")],
      swiftSettings: [
        .define("STREAM_PARSING_BENCHMARKS"),
        .enableExperimentalFeature("Lifetimes")
      ],
      plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
    )
  ],
  swiftLanguageModes: [.v6]
)
