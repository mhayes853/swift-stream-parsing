// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "SmokeTests",
  dependencies: [.package(name: "swift-stream-parsing", path: "..")],
  targets: [
    .executableTarget(
      name: "EmbeddedSmoke",
      dependencies: [.product(name: "StreamParsingCore", package: "swift-stream-parsing")],
      swiftSettings: [
        .enableExperimentalFeature("Embedded"),
        .unsafeFlags(["-wmo", "-Osize"])
      ]
    ),
    .executableTarget(
      name: "NoLifetimeSmoke",
      dependencies: [.product(name: "StreamParsing", package: "swift-stream-parsing")]
    )
  ],
  swiftLanguageModes: [.v6]
)
