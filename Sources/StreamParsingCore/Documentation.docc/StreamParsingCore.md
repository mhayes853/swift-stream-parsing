# ``StreamParsingCore``

Stream-first parsing helpers built on a macro-generated value model and a streaming JSON parser.

## Overview

`@StreamParseable` derives a `Partial` helper and `StreamParseableValue` implementation for your struct so you can drive it with `PartialsStream`, the JSON parser, and the sequence helpers that emit every partial state.

## Quick Start

```swift
import StreamParsing

@StreamParseable(partialMembers: .optional)
struct Profile {
  var id: Int
  var name: String
  var isActive: Bool
}

let parser = JSONStreamParser<Profile.Partial>()
var stream = PartialsStream(initialValue: .initialParseableValue(), from: parser)
for byte in Data("{\"id\":1,\"name\":\"DocC\",\"isActive\":true}".utf8) {
  try stream.next(byte)
}
let partial = try stream.finish()
print(partial.name)
```

## Streaming partial values

`PartialsStream` feeds bytes to a `StreamParser` and exposes the latest value with each call to `next(_:)` and `finish()`. The same logic powers the `Sequence` and `AsyncSequence` `partials(of:from:)` helpers so you can collect partial values when working with batched or asynchronous byte sources.

## JSON parsing

`JSONStreamParser` accepts a `JSONStreamParserConfiguration` that controls `SyntaxOptions` such as comments, trailing commas, unquoted keys, `Infinity`, and leading decimal points. Use `JSONKeyDecodingStrategy` to decode snake_case keys, leave keys untouched, or provide a custom transformation before wiring the callbacks into the value.

## Macros

The  ``StreamParseable`` macro derives the `Partial` helper, the `streamPartialValue` implementation, and `registerHandlers(in:)` calls for each property. ``StreamParseableMember`` and  ``StreamParseableIgnored`` control how individual stored properties map to JSON keys, while  ``PartialMembersMode``  (`.optional` or `.initialParseableValue`) configures whether the generated members default to `nil` or the type’s initial parseable value.

## Topics

- ``StreamParseable`` (macro)
- ``StreamParseableMember`` / ``StreamParseableIgnored``
- ``PartialMembersMode``
- ``PartialsStream``
- ``JSONStreamParser``
- ``JSONStreamParserConfiguration``
- ``JSONKeyDecodingStrategy``
- ``JSONStreamParsingError``
- ``JSONStreamParserConfiguration.SyntaxOptions``
- ``Sequence/partials(of:from:)``
- ``AsyncSequence/partials(of:from:)``
