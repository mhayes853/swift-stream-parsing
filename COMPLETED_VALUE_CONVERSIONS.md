# Completed-value conversions

`StreamCompletedValueConversion` is a two-way conversion between a parsed source representation
and a model member. The parser accumulates the source incrementally, calls `convertToValue`
**once per completed occurrence**, and caches its result. This differs from
`StreamStringConvertible`, whose append operation handles successive fragments.

```swift
import Foundation
import StreamParsing

enum UnixSeconds: StreamCompletedValueConversion {
  typealias Source = Double

  static func convertToValue(_ source: borrowing Source.View) throws(InvalidTimestamp) -> Date {
    guard source.value.isFinite else { throw InvalidTimestamp() }
    return Date(timeIntervalSince1970: source.value)
  }

  static func convertFromValue(_ value: Date) -> Double {
    value.timeIntervalSince1970
  }

  struct InvalidTimestamp: Error {}
}

@StreamParseable
struct Event {
  @StreamParseableMember(key: "created_at", completedConversion: UnixSeconds.self)
  var createdAt: Date = Date(timeIntervalSince1970: 0)
}

var stream = PartialsStream<Event.Partial>(from: .json())
try stream.next(#"{"created_at":12"#.utf8)
// Number boundary has not arrived, so createdAt is still absent.
try stream.next("3}".utf8)
let partial = try stream.finish()
print(partial.createdAt?.source as Any) // 123.0
print(partial.createdAt?.value as Any)  // Date corresponding to 123 seconds after the epoch
let event = Event(streamPartial: partial)
```

## Source representations and completion

`Source` can be any `Sendable` `StreamParseableRoot`: for example `StreamString`, `Int`, `Bool`,
`StreamArray<Double>`, a fixed-size SIMD/inline array, a `StreamDictionary`, or a generated
object `Partial`. `Value` must be `Sendable` and match the member's unwrapped type.
`convertToValue` borrows `Source.View`; it need not copy the source to read it.

- Strings convert at the closing quote, after JSON escapes have been decoded.
- Numbers convert at a confirmed token boundary, including valid document EOF.
- Booleans convert when their literal finishes.
- Arrays and objects convert at their closing delimiter. Nested conversions finish first.
- A completed container may still have missing required model members. The strategy decides
  whether such a source is acceptable.

Completion is field/value completion, not document completion. Later chunks, reads, snapshots,
and `finish()` do not repeat a successful conversion. A duplicate object key starts a fresh
source and result; converted strings and containers do not concatenate/resume earlier occurrences.
Numbers and booleans emit no source updates until their token completes. Consequently, when
such a field repeats, its previous cached value can remain visible during the unfinished token;
`observeField` reports `incomplete(nil)` for that interval instead of exposing the earlier value.
An interrupted source does not convert. The generic implementation retains the source; it is
not an incremental reduction API for unbounded collections.

## Generated storage and model conversion

The macro emits `ConvertedPartial<UnixSeconds>?` for the example's partial member. Its
read-only `source` exposes parsing progress, `value` is nil until conversion succeeds, and
`conversionError` retains a strategy error on failure. Its borrowed view exposes a borrowed
source view and the cached value. The `.streamInitialValue` partial-member mode also works;
nonoptional wrapper storage initially has no converted value.

The conceptual expansion is:

```swift
struct Partial {
  var createdAt: ConvertedPartial<UnixSeconds>?
  // Generated views, schema, initializer, and observation metadata.
}

// Model -> partial:
ConvertedPartial<UnixSeconds>(value: createdAt)
// Calls convertFromValue(createdAt), then stores source and the already available value.

// Partial -> model:
partial.createdAt?.value
// Reads the cached value; does not call convertToValue again.
```

`init(streamPartial:)` requires converted values for nonoptional members. An optional member
can be absent/null, but a present wrapper without a converted value prevents strict conversion.
`init(orInitial:)` uses an explicit declared default for a nonoptional converted member and
nil for an optional member. Nonoptional converted members without defaults are diagnosed by
the macro; it does not invent destination values or run a throwing conversion to obtain them.

`convertFromValue` must be nonthrowing and return a valid source that converts back to a
semantically equivalent value. A canonical spelling is sufficient. Model-to-partial conversion
caches the supplied value directly and never invokes `convertToValue` to validate it again.

## Errors, observation, and configuration

Invalid completed values produce `JSONParsingError` with
`.sinkRejectedToken(StreamSinkFailure(reason: .conversionFailed))`. The failing wrapper retains
the original error in `conversionError`; with `PartialsStream`, it can be inspected through
`current` after catching the parse error. Malformed JSON, wrong source types, and source-capacity
failures retain their existing error reasons. A failed conversion never publishes a successful
completed field observation. Async iterators terminate after the error, including their copies.

Missing and null keep existing partial-storage behavior. Use `observeField` to distinguish
`.missing`, `.null`, `.incomplete`, and `.complete`. An incomplete converted wrapper exposes
its source; a completed wrapper contains the cached destination value.

`key:` and `keyNames:` can accompany `completedConversion:` or be supplied in another member
attribute. The strategy must be written as a type followed by `.self`. Only one strategy is
allowed per member. Capacity hints on converted members are currently rejected. Public model
members require appropriately visible strategy types. Strategies also work in Embedded Swift
when their source, value, and error types support it.
`ConversionError` is inferred from the typed `throws` declaration; nonthrowing strategies infer
`Never`. The partial retains `ConversionError?`, without erasing the error to `any Error`.
On Embedded, drive the converted partial through `JSONParser` and `PartialSink`;
`PartialsStream` still uses untyped errors.

The wrapper can also be used directly with `PartialsStream(initialValue:from:)` at roots or as
an element/value of `StreamArray` and `StreamDictionary`, including optional elements.

Implementation tests, assembly findings, and real-payload throughput measurements are recorded
in [COMPLETED_VALUE_CONVERSION_EVALUATION.md](COMPLETED_VALUE_CONVERSION_EVALUATION.md).
