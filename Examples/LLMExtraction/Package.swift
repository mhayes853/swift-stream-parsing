// swift-tools-version: 6.2

import PackageDescription

// A separate package, so the library's own manifest never has to know about llama.cpp.
let package = Package(
  name: "LLMExtraction",
  platforms: [.macOS(.v13)],
  dependencies: [
    // Named explicitly: a path dependency's identity defaults to its directory name, which
    // breaks the build from a git worktree whose directory is not called swift-stream-parsing.
    .package(name: "swift-stream-parsing", path: "../.."),
    // Apple platforms only; it wraps llama.cpp's prebuilt XCFramework. SwiftPM still downloads
    // the (unused) artifact on other platforms, where `CLlama` links the system library instead.
    .package(url: "https://github.com/mattt/llama.swift", .upToNextMajor(from: "2.10549.0"))
  ],
  targets: [
    // llama.cpp as installed by the system package manager, found through `llama.pc`.
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
      // `@StreamParseable` generates borrowed `~Escapable` views, which need both of these in
      // whichever module applies the macro.
      swiftSettings: [
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("AddressableTypes")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
