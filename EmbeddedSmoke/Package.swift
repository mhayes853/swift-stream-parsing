// swift-tools-version: 6.2

import PackageDescription

// Builds a freestanding executable under Embedded Swift and links it, which is the only way to
// catch the failures that matter here: existentials, dynamic casts, metatypes, key paths,
// untyped throws and unspecialized generics all compile fine on Darwin and only fail when the
// embedded compiler has to lower them, or when the linker cannot find a symbol.
//
// Run with:
//   swiftly run +6.3.2 swift build --package-path EmbeddedSmoke \
//     --swift-sdk swift-6.3.2-RELEASE_wasm-embedded
let package = Package(
  name: "EmbeddedSmoke",
  products: [.executable(name: "EmbeddedSmoke", targets: ["EmbeddedSmoke"])],
  targets: [
    .executableTarget(
      name: "EmbeddedSmoke",
      swiftSettings: [
        .enableExperimentalFeature("Embedded"),
        .unsafeFlags(["-wmo", "-Osize"])
      ]
    )
  ]
)
