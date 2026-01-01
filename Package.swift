// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "swift-stream-parsing",
  platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1)],
  products: [.library(name: "StreamParsing", targets: ["StreamParsing"])],
  traits: [
    .trait(
      name: "StreamParsingSwiftCollections",
      description: "Adds integrations for swift-collections types."
    ),
    .trait(
      name: "StreamParsingTagged",
      description: "Adds integrations for Tagged."
    )
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.3"),
    .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.6.4"),
    .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"603.0.0"),
    .package(url: "https://github.com/apple/swift-collections", from: "1.3.0"),
    .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0")
  ],
  targets: [
    .target(name: "StreamParsing", dependencies: ["StreamParsingCore", "StreamParsingMacros"]),
    .target(
      name: "StreamParsingCore",
      dependencies: [
        .product(
          name: "Collections",
          package: "swift-collections",
          condition: .when(traits: ["StreamParsingSwiftCollections"])
        ),
        .product(
          name: "Tagged",
          package: "swift-tagged",
          condition: .when(traits: ["StreamParsingTagged"])
        )
      ]
    ),
    .macro(
      name: "StreamParsingMacros",
      dependencies: [
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax")
      ]
    ),
    .testTarget(
      name: "StreamParsingTests",
      dependencies: ["StreamParsing", .product(name: "CustomDump", package: "swift-custom-dump")]
    ),
    .testTarget(
      name: "StreamParsingMacrosTests",
      dependencies: [
        "StreamParsingMacros",
        .product(name: "MacroTesting", package: "swift-macro-testing")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
