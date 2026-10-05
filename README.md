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
  .partials(of: Profile.self, from: .json())

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

The `@StreamParseable` macro generates a `Partial` struct with all optional members, and the
`StreamParseable` conformance that converts between the two. A partial is what a stream writes
into, and every member is `nil` until the parser produces it:

```swift
extension Profile: StreamParseable {
  struct Partial: StreamParseable, StreamParseableObject, Sendable {
    typealias Partial = Self

    var id: Int.Partial?          // Int?
    var name: String.Partial?     // StreamString?
    var isActive: Bool.Partial?   // Bool?

    init(id: Int.Partial? = nil, name: String.Partial? = nil, isActive: Bool.Partial? = nil)

    // Also generated: the schema the parser routes tokens through, and a borrowed `View`.
  }

  var streamPartialValue: Partial
  init?(streamPartial: Partial)   // nil until every member has arrived
  init(orInitial: Partial)        // absent members fall back to their initial values
}
```

Additionally, all stored members on an `@StreamParseable` must also conform to the `StreamParseable` protocol. Naturally, the `@StreamParseable` macro handles the protocol conformance for you.

## Streaming into a type

The convenience methods are one-shot or lazy views over a `PartialsStream`, which is generic over
the type being parsed. Feed it bytes as they arrive, and read the partial whenever you like:

```swift
var stream = PartialsStream<Profile>(from: .json())
for chunk in chunks {
  try stream.next(chunk)
  render(stream.current)            // a `Profile.Partial` snapshot
}
let partial = try stream.finish()
let profile = Profile(streamPartial: partial)  // `nil` if the document left a member out
let filled = Profile(orInitial: partial)       // `""`, `0`, `false` for whatever it left out
```

Everywhere a type is named (`PartialsStream<Profile>`, `partials(of: Profile.self, ...)`,
`ObservedFieldPath<Profile, StreamString>`), the model works, and so does its partial
(`Profile.Partial`), which is itself parseable and is its own partial. A scalar or a standard
collection works too: `PartialsStream<[Profile]>` stores a `StreamArray<Profile.Partial>`.

The synchronous and asynchronous drivers are built on it:

```swift
// Every snapshot, retained.
let partials = try bytes.partials(of: Profile.self, from: .json())

// Lazily, one update at a time.
var updates = bytes.partialIterator(of: Profile.self, from: .json())
while let update = try updates.next() {
  print(update.value, update.isComplete)
}

// Without taking a snapshot: a borrowed view of the stream's own storage.
try bytes.withPartialViews(of: Profile.self, from: .json()) { view in
  print(view.name?.value)
} completed: { view in
  print("done", view.name?.value)
}
```

### Custom floating-point types

`Float`, `Double`, `Float16`, and `Float80` (where available) support fast decimal
conversion through `StreamFastFloatConvertible`. A custom type implementing
`BinaryFloatingPoint` and `LosslessStringConvertible` can opt into the same conversion:

```swift
extension BFloat16: StreamFastFloatConvertible {}
```

The default number initializer tries Clinger's exact path, then Eisel–Lemire, then
the internal fallback using the complete token. That fallback normally uses the
type's string initializer; binary16 formats get exact midpoint checks to avoid
the standard library's intermediate `Float` rounding. The default Eisel–Lemire
kernel supports 2–64 bits of precision and decimal exponents from -342 through 308.
`Float80` uses wider intermediate arithmetic within that range and the string fallback
outside it. Results are rounded directly to the destination format, preserving signed
zero; values that overflow to infinity are rejected.

Types can override `static func streamConvertDecimal(magnitude: UInt64, exponent: Int,
negative: Bool) -> Self?` to supply their own fast conversion. Returning `nil` requests
the internal fallback. Significands that overflow the parser's accumulator bypass the
fast conversion and use the complete token.

To use the type as a scalar parse target or an `@StreamParseable` member, also conform
it to `StreamInitializable`, `StreamPartial`, and `StreamParseable`; their existing
defaults supply zero initialization and scalar parsing.

### Key names

Each member is read from the key it's named after. `keyDecodingStrategy` derives the keys from the names instead, like `JSONDecoder`'s, and `@StreamParseableMember` names a member's keys outright, which no strategy converts:

```swift
@StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
struct Tweet {
  var createdAt: String          // "created_at"
  var inReplyToStatusID: Int?    // "in_reply_to_status_id"
  @StreamParseableMember(key: "full_text")
  var text: String
}

@StreamParseable(keyDecodingStrategy: .custom { "x_" + $0 })
struct Extension {
  var requestID: String          // "x_requestID"
}
```

The keys are derived once, as the macro expands for a built-in strategy and when the type's schema is built otherwise, so a strategy costs nothing while parsing. Each `@StreamParseable` type declares its own strategy; a member type follows the strategy it declares.

### String storage

A `String` member is a `StreamString` in the `Partial`: it takes raw UTF-8 and decodes once when read, and a snapshot shares its sealed blocks. `partialStrings: .string` stores it as a Swift `String` instead, so the partial reads like the model:

```swift
@StreamParseable(partialStrings: .string)
struct Message {
  var role: String               // Partial: String?
  var tags: [String]             // Partial: StreamArray<String>?
  @StreamParseableMember(partialStrings: .streamString)
  var content: String            // Partial: StreamString?
}
```

It reaches every `String` in a member's type, as an optional, an array element or a dictionary value. The arrays and dictionaries themselves stay `StreamArray` and `StreamDictionary`. Each chunk is decoded into a `String` and appended, and an append after a snapshot copies the whole string, so taking `current` after every chunk of a long string costs quadratic time. That suits short members, or a partial read once at the end; `@StreamParseableMember(partialStrings:)` overrides the choice for a single member. Each `@StreamParseable` type chooses for its own members, and an enum applies the choice to its associated values.

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
Stage(streamPartial: partial) // nil for a value no case declares
Stage(orInitial: partial)     // .unknown for the same value
```

An enum must name a fallback, either this way or by conforming to `StreamInitializable`, because
`init(orInitial:)` has to be able to produce one.

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

`init?(streamPartial:)` and `init(orInitial:)` work exactly as they do for a no-payload enum —
declining unless exactly one case's key arrived, and requiring that case's payload to be
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
  .partials(of: Profile.self, from: .json())
for try await profilePartial in partials {
  print(profilePartial)
}
```

## Examples

The [LLMExtraction](Examples/LLMExtraction) example parses a local LLM's structured output token by token, logging the typed partial after every chunk.

## Parsers

JSON is the only format, and the JSON parser accepts only strict JSON. Pass the format to each
driver with `from:`.

```swift
let partials: [Profile.Partial] = try json.utf8
  .partials(of: Profile.self, from: .json())
```

`.json(bufferCapacity:)` sets the capacity of the buffer the parser keeps for the tokens it has to
reassemble: a key or a number split across two chunks, and a key written with escapes. The default
is 4096 bytes, and a token that does not fit fails with `JSONParsingError.Reason.bufferExhausted`.
String values stream through in pieces, so the buffer does not limit their length.

## Traits

While the core library itself has 0 dependencies, you can enable the following package traits to integrate with additional dependencies:
- `SwiftCollections` interops the library with types from Swift Collections.
- `Foundation` interops the library with types from Foundation (enabled by default).
- `Tagged` interops the library with `Tagged`.
- `CoreGraphics` interops the library with CoreGraphics types (enabled by default).
- `LifetimeView` enables compiler-checked nonescapable views (disabled by default).

Without `LifetimeView`, macro-generated `Partial.View` and the core collection views are escapable,
pointer-backed `@unsafe` types. This keeps macro consumers on standard Swift settings, but the
caller must keep the originating stream alive and must not retain or use a view across parser
mutation. Unsafe APIs are acknowledged explicitly:

```swift
let title = unsafe stream.withView { view in
  unsafe view.title?.value
}
```

Enable `LifetimeView` to keep the same `View` name and API while making it `~Escapable` and tying
its projections to the stream with compiler-checked lifetimes. Package traits do not enable
compiler experiments in a consuming target, so that target must also enable `Lifetimes`:

```swift
dependencies: [
  .package(
    url: "https://github.com/mhayes853/swift-stream-parsing",
    from: "0.5.0",
    traits: ["LifetimeView"]
  )
],
targets: [
  .target(
    name: "MyTarget",
    dependencies: [.product(name: "StreamParsing", package: "swift-stream-parsing")],
    swiftSettings: [.enableExperimentalFeature("Lifetimes")]
  )
]
```

## Building compatible macros

`StreamParsingMacroSupport` is a SwiftSyntax library for other macro implementations. It
generates partial storage, views, optimized object schemas, enums in each `@StreamParseable`
representation, conversions between the whole type and its partial, and UTF-8 matching syntax. Its
component APIs let a macro compose those pieces with its own declarations, and the
`LifetimeView` trait selects the default view generation mode.

Add the `StreamParsingMacroSupport` product to your macro target. Generated client code uses
`StreamParsing`. See the [macro support guide](Sources/StreamParsingMacroSupport/Documentation.docc/StreamParsingMacroSupport.md)
and the [downstream macro example](SmokeTests/MacroSupport/Sources/SupportMacros/SupportMacros.swift).

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
    traits: ["SwiftCollections"]
  ),
]
```

## License

This library is licensed under the MIT License. See [LICENSE](LICENSE) for details.
