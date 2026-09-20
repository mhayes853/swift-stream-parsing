// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "NoLifetimeSmoke",
  products: [.executable(name: "NoLifetimeSmoke", targets: ["NoLifetimeSmoke"])],
  dependencies: [
    // Deliberately does not enable the LifetimeView trait.
    .package(name: "swift-stream-parsing", path: "..")
  ],
  targets: [
    .executableTarget(
      name: "NoLifetimeSmoke",
      dependencies: [.product(name: "StreamParsing", package: "swift-stream-parsing")]
    )
  ],
  swiftLanguageModes: [.v6]
)
