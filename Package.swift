// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import CompilerPluginSupport
import PackageDescription

let streamParsing128BitIntegers =
  "AvailabilityMacro=StreamParsing128BitIntegers:macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0"

#if compiler(>=6.4)
  let suppressedAssociatedTypes = [SwiftSetting]()
#else
  let suppressedAssociatedTypes = [
    SwiftSetting.enableExperimentalFeature("SuppressedAssociatedTypes")
  ]
#endif

// Lets `View` associated types be `~Escapable`, so a view borrowed from a stream cannot be
// stored past the call that lent it.
let lifetimes = [SwiftSetting.enableExperimentalFeature("Lifetimes")]

// Allows addressable types to participate in protocols whose requirements are otherwise
// implicitly copyable, such as `Equatable` and `Comparable`.
let addressableTypes = [SwiftSetting.enableExperimentalFeature("AddressableTypes")]

let package = Package(
  name: "swift-stream-parsing",
  platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6), .visionOS(.v1)],
  products: [
    .library(name: "StreamParsing", targets: ["StreamParsing"]),
    .library(name: "StreamParsingCore", targets: ["StreamParsingCore"]),
  ],
  traits: [
    .trait(
      name: "StreamParsingSwiftCollections",
      description: "Adds integrations for swift-collections types."
    ),
    .trait(
      name: "StreamParsingTagged",
      description: "Adds integrations for Tagged."
    ),
    .trait(
      name: "StreamParsingFoundation",
      description: "Adds integrations for Foundation types."
    ),
    .trait(
      name: "StreamParsingCoreGraphics",
      description: "Adds integrations for CoreGraphics types."
    ),
    .default(enabledTraits: ["StreamParsingFoundation", "StreamParsingCoreGraphics"])
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.3"),
    .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.6.4"),
    .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"603.0.0"),
    .package(url: "https://github.com/apple/swift-collections", from: "1.3.0"),
    .package(url: "https://github.com/pointfreeco/swift-tagged", from: "0.10.0"),
    .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.1.0"),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.18.7")
  ],
  targets: [
    .target(
      name: "StreamParsing",
      dependencies: ["StreamParsingCore", "StreamParsingMacros"],
      swiftSettings: suppressedAssociatedTypes + lifetimes + addressableTypes
    ),
    // C interoperability target. Executable shims live as inline functions in the header so
    // their scalar/NEON forms can disappear into Swift callers; generated lookup-table storage
    // stays in translation units so importing the header cannot instantiate duplicate tables.
    .target(name: "StreamParsingShims"),
    .target(
      name: "StreamParsingCore",
      dependencies: [
        "StreamParsingShims",
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
      ],
      swiftSettings: [.enableExperimentalFeature(streamParsing128BitIntegers)]
        + suppressedAssociatedTypes + lifetimes + addressableTypes
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
      dependencies: [
        "StreamParsing",
        "StreamParsingCore",
        .product(name: "CustomDump", package: "swift-custom-dump"),
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
      ],
      exclude: ["ParserTests/__Snapshots__"],
      resources: [.process("Resources")],
      swiftSettings: [.enableExperimentalFeature(streamParsing128BitIntegers)]
        + lifetimes + addressableTypes
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
