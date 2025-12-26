// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "swift-stream-parsing",
  products: [.library(name: "StreamParsing", targets: ["StreamParsing"])],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.3.3")
  ],
  targets: [
    .target(name: "StreamParsing"),
    .testTarget(
      name: "StreamParsingTests",
      dependencies: ["StreamParsing", .product(name: "CustomDump", package: "swift-custom-dump")]
    )
  ]
)
