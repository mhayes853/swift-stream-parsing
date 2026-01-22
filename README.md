# Swift Stream Parsing

[![CI](https://github.com/mhayes853/swift-stream-parsing/actions/workflows/ci.yml/badge.svg)](https://github.com/mhayes853/swift-stream-parsing/actions/workflows/ci.yml)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmhayes853%2Fswift-stream-parsing%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/mhayes853/swift-stream-parsing)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmhayes853%2Fswift-stream-parsing%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/mhayes853/swift-stream-parsing)

A Swift toolkit for byte-by-byte parsing.

## Overview

`JSONDecoder` and `Codable` are powerful tools when you need to decode structured JSON bytes, however both of those tools require the entire data payload to be present at decode time.

This is especially problematic for applications such as streaming structured data from LLMs. As a result, the FoundationModels framework has its own set of interfaces for incrementally streaming structured data.

This library offers a dedicated interface for incremental parsing with built-in JSON support.

## Quick Start

First, you create a struct that uses the `@StreamParseable` macro, and then you can begin parsing!

```swift
import StreamParsing

@StreamParseable
struct Profile {
  var id: Int
  var name: String
  var isActive: Bool
}

let json = """
{
  "id": 4,
  "name": "Blob",
  "isActive": true
}
"""

let partials: [Profile.Partial] = try json.utf8
  .partials(of: Profile.Partial.self, from: .json())
```

The `@StreamParseable` macro generates a `Partial` struct with all optional members. Additionally, all stored members on an `@StreamParseable` must also conform to the `StreamParseable` protocol. Naturally, the `@StreamParseable` macro handles the protocol conformance for you.

You can also parse partials from an AsyncSequence of bytes or byte chunks.

```swift
struct AsyncJSONBytesSequence: AsyncSequence {
  typealias Element = UInt8
  
  // ...
}

let partials = AsyncJSONBytesSequence(...)
  .partials(of: Profile.Partial.self, from: .json())
for try await profilePartial in partials {
  print(profilePartial)
}
```

## Parsers

The library comes with a built-in JSON parser, and you can pass a custom configuration to the parser to relax constraints of key names and syntax.

```swift
let configuration = JSONStreamParserConfiguration(
  syntaxOptions: [.comments, .trailingCommas],
  keyDecodingStrategy: .convertFromSnakeCase
)

let partials: [Profile.Partial] = try json.utf8
  .partials(of: Profile.Partial.self, from: .json(configuration: configuration))
```

## Traits

While the core library itself has 0 dependencies, you can enable the following package traits to integrate with additional dependencies:
- `StreamParsingSwiftCollections` interops the library with types from Swift Collections.
- `StreamParsingFoundation` interops the library with types from Foundation (enabled by default).
- `StreamParsingTagged` interops the library with `Tagged`.
- `StreamParsingCoreGraphics` interops the library with CoreGraphics types (enabled by default).

## Installation
You can add Swift Stream Parsing to an Xcode project by adding it to your project as a package.

> [https://github.com/mhayes853/swift-stream-parsing](https://github.com/mhayes853/swift-stream-parsing)

> ⚠️ At of the time of writing this, Xcode 26.2 does not seem to include a UI for enabling traits on swift packages through the `Files > Add Package Dependencies` menu. If you want to enable traits, you will have to install the library inside a local swift package that lives outside your Xcode project.

If you want to use Swift Stream Parsing in a [SwiftPM](https://swift.org/package-manager/) project, it’s as simple as adding it to your `Package.swift`:

```swift
dependencies: [
  .package(
    url: "https://github.com/mhayes853/swift-stream-parsing",
    from: "0.1.0",
    // You can omit the traits if you don't need any of them.
    traits: ["StreamParsingSwiftCollections"]
  ),
]
```

## License

This library is licensed under the MIT License. See [LICENSE](LICENSE) for details.
