# Swift Stream Parsing

[![CI](https://github.com/mhayes853/swift-stream-parsing/actions/workflows/ci.yml/badge.svg)](https://github.com/mhayes853/swift-stream-parsing/actions/workflows/ci.yml)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmhayes853%2Fswift-stream-parsing%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/mhayes853/swift-stream-parsing)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmhayes853%2Fswift-stream-parsing%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/mhayes853/swift-stream-parsing)

A Swift interface for parsing values byte-by-byte.

## Overview

``@StreamParseable`` derives a `Partial` helper and wire-up for your struct so it can be driven by ``PartialsStream`` and the ``JSONStreamParser``. The library also exposes async-friendly helpers and `Sequence` extensions that surface every value state produced as bytes arrive.

## Quick Start

```swift
import StreamParsing

@StreamParseable
struct Profile {
  var id: Int
  var name: String
  var isActive: Bool
}

let parser = JSONStreamParser<Profile.Partial>(
  configuration: JSONStreamParserConfiguration(
    syntaxOptions: [.trailingCommas, .singleQuotedStrings],
    keyDecodingStrategy: .convertFromSnakeCase
  )
)
var stream = PartialsStream(initialValue: .initialParseableValue(), from: parser)

for byte in Data("{\"id\":1,\"name\":\"Blob\",\"is_active\":true}".utf8) {
  try stream.next(byte)
}
let partial = try stream.finish()
print(partial.name)
```

### Streaming partials

Use ``PartialsStream`` to feed bytes or sequences of bytes to a parser and observe the partial value state after each append. `Sequence` and `AsyncSequence` helpers (``partials(of:from:)``) expose the same value stream when you want to work with batches or async byte sources.

### JSON parser configuration

``JSONStreamParserConfiguration.SyntaxOptions`` lets you relax strict JSON (allow comments, trailing commas, unquoted keys, `Infinity`, etc.). The parser also respects ``JSONKeyDecodingStrategy``, so you can convert snake_case keys or provide a bespoke transformation when wiring ``StreamParseable`` values into the parser.

## Installation

Add the package to your `Package.swift` dependencies:

```swift
.package(url: "https://github.com/mhayes853/swift-stream-parsing", from: "0.1.0")
```

Then add the `StreamParsing` product to any target that needs parsing support.

## License

This library is licensed under the MIT License. See [LICENSE](LICENSE) for details.
