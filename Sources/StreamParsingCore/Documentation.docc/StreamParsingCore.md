# ``StreamParsingCore``

Stream-first parsing helpers built on a macro-generated value model and a streaming JSON parser.

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

To consume synchronous input lazily instead of retaining every snapshot, use
``PartialIterator``:

```swift
var updates = json.utf8.partialIterator(of: Profile.self, from: .json())
while let update = try updates.next() {
  print(update.value, update.isComplete)
}
```

The iterator is noncopyable and emits after each byte (or chunk), followed by one
completed update after EOF validation. Further calls return `nil` after completion
or an error. `isComplete` describes document validation, not model-field presence.

To read without a whole-value snapshot, use a scoped view:

```swift
try json.utf8.withPartialViews(of: Profile.self, from: .json()) { view, isComplete in
  print(view.name?.value, isComplete)
}
```

A view cannot escape the callback. Members read through it can be copied and retained.
The final callback also uses a view, via ``PartialsStream/finishWithView(_:)``.

Observe one field through a borrowed view and suppress unchanged values:

```swift
var names = json.utf8.partialIterator(of: Profile.self, from: .json())
  .project { $0.name?.value }
  .removeDuplicateUpdates()
while let update = try names.next() {
  print(update.value, update.isComplete)
}
```

Async partial sequences support the same `project` and `removeDuplicateUpdates`
operators. Projection happens before copying the root value. Filtering retains one
previously emitted value and always forwards document completion, even if the selected
field is unchanged. Both APIs can also filter whole snapshots without a projection.
Use `by:` to supply a custom equivalence predicate.

Projection preserves the selected representation. To distinguish missing, null, incomplete,
and complete fields, opt into ``ObservedField`` instead:

```swift
var names = try json.utf8.partialIterator(of: Profile.self, from: .json())
  .observeField(\.name)
  .removeDuplicateUpdates()
while let update = try names.next() {
  print(update.value, update.isComplete)
}
```

Field completion is separate from validated document EOF. A string can finish before its
object closes, and a completed object can still have absent model members. Observers support
direct stored fields on object roots with schema field tables; configure them before reading
input. ``ObservedFieldPath`` validates a reusable selection, including schema key aliases.
The macro generates `streamObservationFields` for validation without reflection SPI. Custom
roots opt in by listing all direct stored members in that property. The selectors are
unavailable in Embedded Swift. Ordinary value projection needs no field-state tracking.

The `@StreamParseable` macro generates a `Partial` struct with all optional members, and the
``StreamParseable`` conformance that converts between the two. A partial is what a stream writes
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
}
```

Additionally, all stored members on an `@StreamParseable` must also conform to the ``StreamParseable`` protocol. Naturally, the `@StreamParseable` macro handles the protocol conformance for you.

## Streaming into a type

``PartialsStream`` is generic over the type being parsed. Feed it bytes as they arrive, and read the
partial whenever you like:

```swift
var stream = PartialsStream<Profile>(from: .json())
for chunk in chunks {
  try stream.next(chunk)
  render(stream.current)            // a `Profile.Partial` snapshot
}
let partial = try stream.finish()
let profile = Profile(streamPartial: partial)  // `nil` if the document left a member out
```

Everywhere a type is named (`PartialsStream<Profile>`, `partials(of: Profile.self, ...)`,
``ObservedFieldPath``), the model works, and so does its partial (`Profile.Partial`), which is
itself parseable and is its own partial. A scalar or a standard collection works too:
`PartialsStream<[Profile]>` stores a ``StreamArray`` of `Profile.Partial`.

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

## Parsers

JSON is the only format, and the JSON parser accepts only strict JSON. Pass the format to each
driver with `from:`.

```swift
let partials: [Profile.Partial] = try json.utf8
  .partials(of: Profile.self, from: .json())
```

``JSONStreamFormat/json(bufferCapacity:)`` sets the capacity of the buffer the parser keeps for the
tokens it has to reassemble: a key or a number split across two chunks, and a key written with
escapes. The default is 4096 bytes, and a token that does not fit fails with
``JSONParsingError/Reason/bufferExhausted``. String values stream through in pieces, so the buffer
does not limit their length.

## Traits

While the core library itself has 0 dependencies, you can enable the following package traits to integrate with additional dependencies:
- `SwiftCollections` interops the library with types from Swift Collections.
- `Foundation` interops the library with types from Foundation (enabled by default).
- `Tagged` interops the library with `Tagged`.
- `CoreGraphics` interops the library with CoreGraphics types (enabled by default).
- `LifetimeView` enables compiler-checked nonescapable views (disabled by default).

Without `LifetimeView`, generated and core `View` types are escapable `@unsafe` pointer
projections. Keep the originating stream alive and do not retain or use a view across parser
mutation. With strict memory safety, acknowledge these operations explicitly:

```swift
let title = unsafe stream.withView { view in
  unsafe view.title?.value
}
```

Enabling `LifetimeView` preserves the same `View` names while making them `~Escapable` and adding
compiler-checked lifetime dependencies. The consuming target must separately enable the
experimental `Lifetimes` compiler feature; Swift package traits do not propagate compiler flags.

## Completed-value conversions

Use `@StreamParseableMember(completedConversion: Strategy.self)` to parse one representation
and expose a different model type. A ``StreamCompletedValueConversion`` declares a source
root type and implements `convertToValue(_:)` and `convertFromValue(_:)`.

```swift
@StreamParseable
struct Event {
  @StreamParseableMember(completedConversion: UnixSeconds.self)
  var createdAt: Date = Date(timeIntervalSince1970: 0)
}
```

The generated partial stores ``ConvertedPartial``. Its `source` updates incrementally; its
`value` is cached after the complete string, number, boolean, array, or object is validated
and converted. Nonoptional converted members need a declared default for total model
conversion. Optional members preserve the existing missing/null behavior; `observeField`
can distinguish those states. Model-to-partial conversion calls `convertFromValue`, without
repeating `convertToValue`. Conversion errors use typed `throws` and remain concrete in the partial, including in Embedded Swift.

## Schemas and the schema cache

A ``StreamPartial`` describes how the parser writes into it with a ``StreamSchema``. A type
can have one schema for each ``StreamSchema/Usage``, meaning where the parser meets the value:
``StreamPartial/streamSchema`` at the root,
``StreamPartial/streamArrayElementSchema`` as an array element,
``StreamPartial/streamDictionaryValueSchema`` as a dictionary value, and
``StreamContainerPartial/streamObjectMemberSchema`` as a declared member of an object. Every usage
defaults to the root schema. Only `Optional` differs, because the slot of an array element or
dictionary value it sits in is opened already materialised.

A schema is read when a stream starts and whenever a parent schema is built, never per token. Build
it once and keep it in a ``StreamSchemaCache``. A generic type reads it by type; a concrete type
keeps its ``StreamSchemaCache/Entry`` in a `static let`, which skips the lookup and costs about what
reading a `static let` schema would:

```swift
extension Pair: StreamPartial where A: StreamPartial, B: StreamPartial {
  static var streamSchema: StreamSchema {
    StreamSchemaCache.shared.schema(for: Self.self) {
      StreamSchema(shape: .object, ...)
    }
  }
}

extension Point: StreamPartial {
  private static let schemaEntry = StreamSchemaCache.shared.entry(for: Point.self) {
    StreamSchema(shape: .object, ...)
  }
  static var streamSchema: StreamSchema { Self.schemaEntry.schema }
}
```

An entry owns its build closure, which is `@Sendable` because the entry keeps it: every read of
the entry, and a read of the same key by type, builds with it, on first read and after removal.
The first closure supplied for a key is the one kept.

Key each schema with `Self.self` and the usage the requirement serves. A schema cached under
another type's key writes through a layout it does not describe. The build closure may run more
than once: two threads that miss at once both build, and on Embedded Swift a read by type is not
cached. So it must have no side effects, and must not read the schema it is building.

`@StreamParseable` keeps its schemas in ``StreamSchemaCache/shared``, or in the cache its
`schemaCache:` argument names. A stream owns every schema it uses, because it holds its root schema
and each schema holds its children, so removing them (``StreamSchemaCache/removeAll()``) never
affects a stream in flight. It also frees nothing a cached parent still holds: memory is released
along ownership, not cache boundaries.

The parser borrows the schema of each container it enters rather than retaining it. A hand-written
`enterField` that returns a ``StreamFrame`` must therefore return a schema that something else owns
for the whole parse: a child the enclosing schema's field table or element schema holds, or one
cached in a ``StreamSchemaCache``. A schema built inside the closure and held only by the frame is
freed under the sink.
