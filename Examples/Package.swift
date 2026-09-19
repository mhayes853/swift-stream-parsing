// swift-tools-version: 6.2

import PackageDescription

// The examples live in their own package so the library's manifest never learns about
// llama.cpp: `replay` needs nothing beyond the library itself, and only `live` links an LLM.
let applePlatforms: [Platform] = [.macOS, .iOS, .tvOS, .watchOS, .visionOS]

let package = Package(
  name: "swift-stream-parsing-examples",
  platforms: [.macOS(.v13)],
  dependencies: [
    // Named explicitly: a path dependency's identity defaults to its directory name, which
    // breaks the build from a git worktree whose directory is not called swift-stream-parsing.
    .package(name: "swift-stream-parsing", path: ".."),
    // Apple platforms only; it wraps llama.cpp's prebuilt XCFramework. SwiftPM still downloads
    // the (unused) artifact on other platforms, where `CLlama` links the system library instead.
    .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.10549.0"))
  ],
  targets: [
    // The model types, chunk sources, fixture format, and the terminal logger.
    .target(
      name: "DemoCore",
      dependencies: [
        .product(name: "StreamParsing", package: "swift-stream-parsing")
      ],
      // `@StreamParseable` generates borrowed `~Escapable` views, which need both of these in
      // whichever module applies the macro.
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("AddressableTypes")
      ]
    ),
    // llama.cpp as installed by the system package manager, found through `llama.pc`.
    .systemLibrary(
      name: "CLlama",
      pkgConfig: "llama",
      providers: [.brew(["llama.cpp"]), .apt(["llama.cpp"])]
    ),
    // An in-process LLM that streams grammar-constrained JSON token by token.
    .target(
      name: "LlamaSource",
      dependencies: [
        "DemoCore",
        .target(name: "CLlama", condition: .when(platforms: [.linux, .windows, .android])),
        .product(
          name: "LlamaSwift",
          package: "llama.swift",
          condition: .when(platforms: applePlatforms)
        )
      ]
    ),
    // `swift run replay`: parses a recorded token stream. No model or llama.cpp required.
    .executableTarget(name: "replay", dependencies: ["DemoCore"]),
    // `swift run live`: parses what a local model generates, as it generates it.
    .executableTarget(name: "live", dependencies: ["DemoCore", "LlamaSource"])
  ],
  swiftLanguageModes: [.v6]
)
