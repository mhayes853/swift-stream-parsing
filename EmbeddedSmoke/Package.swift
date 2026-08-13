// swift-tools-version: 6.2

import PackageDescription

// Builds a freestanding executable under Embedded Swift and links it, which is the only way to
// catch the failures that matter here: existentials, dynamic casts, metatypes, key paths,
// untyped throws and unspecialized generics all compile fine on Darwin and only fail when the
// embedded compiler has to lower them, or when the linker cannot find a symbol.
//
// Swift 6.4 or newer: 6.3.2 rejects the view layer's `associatedtype View: ~Copyable`.
//
// Run with:
//   swiftly run +6.4.x-snapshot-2026-08-01 swift build --package-path EmbeddedSmoke \
//     --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-01-a_wasm-embedded
let package = Package(
  name: "EmbeddedSmoke",
  products: [.executable(name: "EmbeddedSmoke", targets: ["EmbeddedSmoke"])],
  dependencies: [.package(path: "..")],
  targets: [
    .executableTarget(
      name: "EmbeddedSmoke",
      dependencies: [.product(name: "StreamParsingCore", package: "swift-stream-parsing")],
      swiftSettings: [
        .enableExperimentalFeature("Embedded"),
        .unsafeFlags(["-wmo", "-Osize"])
      ]
    )
  ]
)
