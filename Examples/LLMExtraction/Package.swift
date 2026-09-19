// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "LLMExtraction",
  platforms: [.macOS(.v13)],
  dependencies: [
    // Named explicitly: a path dependency's identity defaults to its directory name, which
    // breaks the build from a git worktree whose directory is not called swift-stream-parsing.
    .package(name: "swift-stream-parsing", path: "../.."),
    .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.10549.0"))
  ],
  targets: [
    .systemLibrary(
      name: "CLlama",
      pkgConfig: "llama",
      providers: [.brew(["llama.cpp"]), .apt(["llama.cpp"])]
    ),
    .executableTarget(
      name: "LLMExtraction",
      dependencies: [
        .product(name: "StreamParsing", package: "swift-stream-parsing"),
        .target(name: "CLlama", condition: .when(platforms: [.linux, .windows, .android])),
        .product(
          name: "LlamaSwift",
          package: "llama.swift",
          condition: .when(platforms: [.macOS, .iOS, .tvOS, .watchOS, .visionOS])
        )
      ],
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("AddressableTypes")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
