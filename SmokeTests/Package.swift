// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "SmokeTests",
  platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1)],
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
