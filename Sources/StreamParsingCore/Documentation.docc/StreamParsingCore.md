# ``StreamParsingCore``

Stream-first parsing helpers built on a macro-generated value model and a streaming JSON parser.

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

The `@StreamParseable` macro generates a `Partial` struct with all optional members. Additionally, all stored members on an `@StreamParseable` must also conform to the ``StreamParseable`` protocol. Naturally, the `@StreamParseable` macro handles the protocol conformance for you.

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
