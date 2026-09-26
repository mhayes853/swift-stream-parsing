// swift-tools-version: 6.3

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "MacroSupportSmoke",
  traits: [.trait(name: "LifetimeView")],
  dependencies: [
    .package(
      name: "swift-stream-parsing",
      path: "../..",
      traits: [
        .defaults,
        .trait(name: "LifetimeView", condition: .when(traits: ["LifetimeView"]))
      ]
    ),
    .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"603.0.0")
  ],
  targets: [
    .macro(
      name: "SupportMacros",
      dependencies: [
        .product(name: "StreamParsingMacroSupport", package: "swift-stream-parsing"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
      ]
    ),
    .executableTarget(
      name: "MacroSupportSmoke",
      dependencies: [
        "SupportMacros",
        .product(name: "StreamParsing", package: "swift-stream-parsing")
      ],
      swiftSettings: [.enableExperimentalFeature("Lifetimes")]
    )
  ],
  swiftLanguageModes: [.v6]
)
