# Swift Stream Parsing

[![CI](https://github.com/mhayes853/swift-stream-parsing/actions/workflows/ci.yml/badge.svg)](https://github.com/mhayes853/swift-stream-parsing/actions/workflows/ci.yml)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmhayes853%2Fswift-stream-parsing%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/mhayes853/swift-stream-parsing)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fmhayes853%2Fswift-stream-parsing%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/mhayes853/swift-stream-parsing)

A Swift toolkit for type-safe incremental parsing.

## Overview

`JSONDecoder` and `Codable` are powerful tools when you need to decode structured JSON bytes, however both of those tools require the entire data payload to be present at decode time.

This is especially problematic for applications such as streaming structured data from LLMs. For example, the FoundationModels framework has its own set of interfaces for incrementally streaming structured data.

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

for partial in partials {
  print(partial)
}

// Prints:
// Profile.Partial(id: nil, name: nil, isActive: nil)
// ...
// Profile.Partial(id: Optional(4), name: nil, isActive: nil)
// ...
// Profile.Partial(id: Optional(4), name: Optional("B"), isActive: nil)
// Profile.Partial(id: Optional(4), name: Optional("Bl"), isActive: nil)
// Profile.Partial(id: Optional(4), name: Optional("Blo"), isActive: nil)
// Profile.Partial(id: Optional(4), name: Optional("Blob"), isActive: nil)
// ...
// Profile.Partial(id: Optional(4), name: Optional("Blob"), isActive: Optional(true))
```

The `@StreamParseable` macro generates a `Partial` struct with all optional members. 

```swift
extension Profile: StreamParsingCore.StreamParseable {
  struct Partial: StreamParsingCore.StreamParseableValue,
    StreamParsingCore.StreamParseable {
    typealias Partial = Self

    var id: Int.Partial?
    var name: String.Partial?
    var isActive: Bool.Partial?

    init(
      id: Int.Partial? = nil,
      name: String.Partial? = nil,
      isActive: Bool.Partial? = nil
    ) {
      self.id = id
      self.name = name
      self.isActive = isActive
    }

    static func initialParseableValue() -> Self {
      Self()
    }

    static func registerHandlers(
      in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
    ) {
      handlers.registerKeyedHandler(forKey: "id", \.id)
      handlers.registerKeyedHandler(forKey: "name", \.name)
      handlers.registerKeyedHandler(forKey: "isActive", \.isActive)
    }
  }
}
```

Additionally, all stored members on an `@StreamParseable` must also conform to the `StreamParseable` protocol. Naturally, the `@StreamParseable` macro handles the protocol conformance for you.

### Enums

`@StreamParseable` also applies to enums, in whichever of three forms matches how the enum is
spelled. Each one parses what `Codable` produces for the same declaration, so there is no second
wire format to learn:

| spelling | JSON | `Partial` |
| --- | --- | --- |
| `enum Stage: String` | `"live"` | `StreamString` |
| `enum Stage: Int` | `5` | `Int` |
| `enum Stage` (no raw type) | `{"live":{}}` | a generated struct |

```swift
@StreamParseable
enum Stage: String {
  @StreamParseableDefault
  case unknown
  case live
  case livestream
}
```

`@StreamParseableDefault` names the case a *total* conversion falls back to when the stream
produced nothing the enum can represent. The strict conversion still declines — the two exist to
say different things:

```swift
Stage(streamPartial: partial)            // nil for a value no case declares
Stage.streamValueOrInitial(from: partial) // .unknown for the same value
```

An enum must name a fallback, either this way or by conforming to `StreamInitializable`, because
`streamValueOrInitial` has to be able to produce one.

Cases can accept extra spellings without changing what the enum emits:

```swift
@StreamParseable
enum Stage: String {
  @StreamParseableDefault
  case unknown

  // Parses any of the three; still emits "live".
  @StreamParseableMember(keyNames: ["LIVE", "running"])
  case live
}
```

#### Resolving a case mid-stream

A string value arrives in pieces and carries no "this is finished" signal, so reading a partial
mid-value has to assume something. The rule is **the shortest case the bytes so far are still a
prefix of**:

| bytes so far | resolves to |
| --- | --- |
| `""` | `nil` — a prefix of everything, so it says nothing |
| `"liv"` | `.live` |
| `"live"` | `.live` |
| `"lives"` | `.livestream` |
| `"livid"` | `nil` |

The consequence worth planning for: a case can be **superseded**, not merely filled in. Above,
`.live` becomes `.livestream` as more bytes land. This only affects `String`-raw enums — a number
and an object key both arrive whole, so those two resolve or they do not.

#### Cases with associated values

A raw-less enum's cases can carry associated values, still matching `Codable`'s own wire format
for the same declaration:

```swift
@StreamParseable
enum Block: Codable {
  @StreamParseableDefault
  case unknown
  case text(TextBlock)                 // {"text":{"_0":{...}}}
  case image(url: String, width: Int)  // {"image":{"url":"...","width":...}}
}
```

Each associated value keys its field the same way `Codable`'s synthesis does: a written label
(`url`, `width`), or a positional `_0`, `_1`, ... for an unlabeled one — counted over every
parameter in that case, labeled ones included. Every associated value's type has to itself be
`StreamParseable` (`String`/`Int`/etc. already are).

`init?(streamPartial:)` and `streamValueOrInitial(from:)` work exactly as they do for a no-payload
enum — declining unless exactly one case's key arrived, and requiring that case's payload to be
complete. A payload-bearing `@StreamParseableDefault` case fills its associated values from their
own initial values, recursively, the same way a struct's members do.

`Partial.View` additionally gets a `resolved` property: a borrowed, mid-stream read of whichever
case's key has arrived so far, without materializing an owned snapshot of it.

```swift
stream.withView { partial in
  switch partial.resolved {
  case .unresolved: break
  case .ambiguous: break
  case .unknown: break
  case .text(let view):
    if let body = view._0 {
      print(body.body?.value)  // TextBlock's own `body: String` field
    }
  case .image(let view):
    print(view.url?.value, view.width?.value)
  }
}
```

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

The JSON parser accepts only strict JSON.

### JSON

```swift
let partials: [Profile.Partial] = try json.utf8
  .partials(of: Profile.Partial.self, from: .json())
```

### YAML

```swift
let yaml = """
id: 4
name: Blob
isActive: true
"""

let partials: [Profile.Partial] = try yaml.utf8
  .partials(of: Profile.Partial.self, from: .yaml())

let configuration = YAMLStreamParserConfiguration(
  keyDecodingStrategy: .convertFromSnakeCase
)

let snakeCaseYAML = """
id: 4
name: Blob
is_active: true
"""

let partials = try snakeCaseYAML.utf8.partials(
  of: Profile.Partial.self,
  from: .yaml(configuration: configuration)
)
```

## Traits

While the core library itself has 0 dependencies, you can enable the following package traits to integrate with additional dependencies:
- `StreamParsingSwiftCollections` interops the library with types from Swift Collections.
- `StreamParsingFoundation` interops the library with types from Foundation (enabled by default).
- `StreamParsingTagged` interops the library with `Tagged`.
- `StreamParsingCoreGraphics` interops the library with CoreGraphics types (enabled by default).

## Documentation

The documentation for releases and main are available here.
* [StreamParsing (main)](https://swiftpackageindex.com/mhayes853/swift-stream-parsing/main/documentation/streamparsing/)
* [StreamParsing (0.x.x)](https://swiftpackageindex.com/mhayes853/swift-stream-parsing/~/documentation/streamparsing/)
* [StreamParsingCore (main)](https://swiftpackageindex.com/mhayes853/swift-stream-parsing/main/documentation/streamparsingcore/)
* [StreamParsingCore (0.x.x)](https://swiftpackageindex.com/mhayes853/swift-stream-parsing/~/documentation/streamparsingcore/)

## Installation
You can add Swift Stream Parsing to an Xcode project by adding it to your project as a package.

> [https://github.com/mhayes853/swift-stream-parsing](https://github.com/mhayes853/swift-stream-parsing)

> [!NOTE] 
> Xcode 26.4 is required for using traits directly in Xcode projects.

If you want to use Swift Stream Parsing in a [SwiftPM](https://swift.org/package-manager/) project, it’s as simple as adding it to your `Package.swift`:

```swift
dependencies: [
  .package(
    url: "https://github.com/mhayes853/swift-stream-parsing",
    from: "0.5.0",
    // You can omit the traits if you don't need any of them.
    traits: ["StreamParsingSwiftCollections"]
  ),
]
```

## License

This library is licensed under the MIT License. See [LICENSE](LICENSE) for details.
