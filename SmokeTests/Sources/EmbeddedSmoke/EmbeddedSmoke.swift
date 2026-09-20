import StreamParsingCore

// Embedded Swift smoke test.
//
// Parses a payload through the real parser and a hand written sink, then links the result as a
// freestanding wasm executable. Linking is the point: existentials, dynamic casts, metatypes,
// key paths, untyped throws and unspecialized generics all compile fine on Darwin and only fail
// when the embedded compiler has to lower them, or when the linker cannot find a symbol.
//
// The parser is given a caller supplied buffer rather than the allocating initializer, which is
// how it is meant to be used where there is no heap to speak of.

// MARK: - Sinks

/// Folds the document into counters and a checksum, so the whole path from bytes to values is
/// exercised without a String, an Array, or anything else that allocates in the sink.
struct SmokeSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?

  var objects = 0
  var arrays = 0
  var keys = 0
  var strings = 0
  var numbers = 0
  var booleans = 0
  var nulls = 0

  var keyWordChecksum: UInt64 = 0
  var stringByteChecksum: UInt64 = 0
  var magnitudeSum: UInt64 = 0

  // Both opens answer `.stream`: the smoke exists to lower the whole token path, so nothing
  // here has a subtree it wants skipped.
  mutating func beginObject() -> StreamContainerDisposition {
    self.objects &+= 1
    return .stream
  }
  mutating func endObject() {}
  mutating func beginArray() -> StreamContainerDisposition {
    self.arrays &+= 1
    return .stream
  }
  mutating func endArray() {}

  // The collapsed forms are overridden, which is what generated matchers do: it avoids two of
  // every three sink calls.
  mutating func key(_ bytes: Span<UInt8>) {
    self.keys &+= 1
    self.keyWordChecksum = self.keyWordChecksum &+ bytes.paddedLeadingWord()
  }

  // Keys arrive through the collapsed form because the parser always buffers them, but strings
  // arrive as runs, so they come through begin, chunk and end. Counting in both is what makes
  // the tally the same either way.
  mutating func string(_ bytes: Span<UInt8>) {
    self.strings &+= 1
    self.stringChunk(bytes)
  }

  mutating func stringBegin() { self.strings &+= 1 }

  mutating func stringChunk(_ bytes: Span<UInt8>) {
    var index = 0
    while index < bytes.count {
      self.stringByteChecksum = self.stringByteChecksum &* 31 &+ UInt64(bytes[index])
      index &+= 1
    }
  }

  mutating func stringEnd() {}

  // Exactly one event per number token, whole, at its end.
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.numbers &+= 1
    self.magnitudeSum = self.magnitudeSum &+ info.magnitude
    // Exercises the conversion path too, not just the scan.
    if let value = Int(streamParsing: bytes, info: info) {
      self.magnitudeSum = self.magnitudeSum &+ UInt64(value.magnitude)
    }
  }

  mutating func boolean(_ value: Bool) { self.booleans &+= 1 }
  mutating func null() { self.nulls &+= 1 }

  mutating func events(_ batch: borrowing StreamEventBatch) -> Int {
    let records = batch.records
    var index = 0
    while index < batch.count {
      let record = records[index]
      switch record.kind {
      case .beginObject: self.beginObject()
      case .endObject: self.endObject()
      case .beginArray: self.beginArray()
      case .endArray: self.endArray()
      case .key: self.key(batch.bytes(of: index))
      case .stringBegin: self.stringBegin()
      case .stringChunk: self.stringChunk(batch.bytes(of: index))
      case .stringEnd: self.stringEnd()
      case .number: self.number(batch.bytes(of: index), info: batch.info(of: index))
      case .boolean: self.boolean(record.booleanValue)
      case .null: self.null()
      case .string: self.string(batch.bytes(of: index))
      }
      index &+= 1
    }
    return index
  }
}

// MARK: - Driving the parser

func parse(
  _ payload: StaticString,
  chunk: Int,
  buffer: UnsafeMutableBufferPointer<UInt8>
) -> SmokeSink {
  var parser = JSONParser(buffer: buffer)
  var sink = SmokeSink()
  payload.withUTF8Buffer { input in
    var offset = 0
    while offset < input.count {
      let count = min(chunk, input.count - offset)
      let slice = UnsafeBufferPointer(start: input.baseAddress! + offset, count: count)
      try! parser.parse(slice, into: &sink)
      offset += count
    }
    try! parser.finish(into: &sink)
  }
  return sink
}

// MARK: - Partial to whole

// `_streamValue` and `_streamValueOrInitial` take a closure whose only job is to bind the
// destination type from the property being filled. A `KeyPath` would have done the same and would
// have compiled fine on Darwin, then failed to lower here — which is the entire reason this target
// exists. These two types are written the way the macro writes them, minus the schema boilerplate:
// `Optional` is already a `StreamParseableRoot`, so a partial can be one without a hand written
// schema, and the conversion code under test is identical either way.

struct Reading {
  var meters: Int
}

extension Reading: StreamParseable {
  typealias Partial = Int?

  var streamPartialValue: Partial { self.meters }

  init?(streamPartial partial: Partial) {
    guard let meters = Self._streamValue({ $0.meters }, partial) else { return nil }
    self.meters = meters
  }

  init(orInitial partial: Partial) {
    self.meters = Self._streamValueOrInitial({ $0.meters }, partial)
  }

  static func streamValueOrInitial(from partial: Partial) -> Reading {
    Reading(orInitial: partial)
  }
}

// One level of nesting, so the recursion through `Optional`'s conformance and the promotion that
// lets one signature serve a member the mode wrapped and one the user declared optional are both
// lowered rather than only reasoned about.
struct Nested {
  var inner: Reading?
}

extension Nested: StreamParseable {
  typealias Partial = Reading.Partial?

  var streamPartialValue: Partial { self.inner.streamPartialValue }

  init?(streamPartial partial: Partial) {
    guard let inner = Self._streamValue({ $0.inner }, partial) else { return nil }
    self.inner = inner
  }

  init(orInitial partial: Partial) {
    self.inner = Self._streamValueOrInitial({ $0.inner }, partial)
  }

  static func streamValueOrInitial(from partial: Partial) -> Nested {
    Nested(orInitial: partial)
  }
}

// MARK: - Completed conversions

enum NonnegativeConversion: StreamCompletedValueConversion {
  typealias Source = Int
  enum Invalid: Error { case negative }

  static func convertToValue(_ source: borrowing Source.View) throws(Invalid) -> Int {
    guard source.value >= 0 else { throw .negative }
    return source.value * 2
  }

  static func convertFromValue(_ value: Int) -> Int { value / 2 }
}

enum BooleanConversion: StreamCompletedValueConversion {
  typealias Source = Bool

  // The associated error type is inferred as Never.
  static func convertToValue(_ source: borrowing Source.View) -> Int {
    source.value ? 1 : 0
  }

  static func convertFromValue(_ value: Int) -> Bool { value != 0 }
}

// Forward scalar tokens to the conversion schema without pulling in PartialSink's unrelated
// floating-point routes: the installed wasm SDK lacks their strtod/strtof runtime symbols.
struct ConversionSmokeSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  let root: UnsafeMutableRawPointer
  let schema: StreamSchema

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    record(schema.applyNumber(root, StreamSchema.wholeValueField, bytes, info))
  }

  mutating func boolean(_ value: Bool) {
    record(schema.applyBoolean(root, StreamSchema.wholeValueField, value))
  }

  mutating func beginObject() -> StreamContainerDisposition { preconditionFailure() }
  mutating func endObject() { preconditionFailure() }
  mutating func beginArray() -> StreamContainerDisposition { preconditionFailure() }
  mutating func endArray() { preconditionFailure() }
  mutating func key(_ bytes: Span<UInt8>) { preconditionFailure() }
  mutating func stringBegin() { preconditionFailure() }
  mutating func stringChunk(_ bytes: Span<UInt8>) { preconditionFailure() }
  mutating func stringEnd() { preconditionFailure() }
  mutating func null() { preconditionFailure() }

  mutating func record(_ result: StreamApplyResult) {
    if result != .applied {
      precondition(result == .conversionFailed)
      streamFailure = StreamSinkFailure(reason: .conversionFailed)
    }
  }
}

func parseConverted<C: StreamCompletedValueConversion>(
  _ payload: StaticString,
  into value: inout ConvertedPartial<C>
) -> JSONParsingError? {
  withUnsafeMutablePointer(to: &value) { storage in
    var sink = ConversionSmokeSink(
      root: UnsafeMutableRawPointer(storage),
      schema: ConvertedPartial<C>.streamSchema
    )
    var parser = JSONParser()
    return payload.withUTF8Buffer { input -> JSONParsingError? in
      do throws(JSONParsingError) {
        // Feed scalar source tokens incrementally through the real parser.
        for byte in input { try parser.parse(byte: byte, into: &sink) }
        try parser.finish(into: &sink)
        return nil
      } catch {
        return error
      }
    }
  }
}

func checkCompletedConversions() {
  var number = ConvertedPartial<NonnegativeConversion>()
  precondition(parseConverted("12 ", into: &number) == nil)
  precondition(number.value == 24)
  precondition(number.conversionError == nil)
  let rebuilt = ConvertedPartial<NonnegativeConversion>(value: 24)
  precondition(rebuilt.source == 12)
  precondition(rebuilt.value == 24)

  var invalid = ConvertedPartial<NonnegativeConversion>()
  let failure = parseConverted("-1 ", into: &invalid)
  precondition(failure?.reason == .sinkRejectedToken(.init(reason: .conversionFailed)))
  precondition(invalid.conversionError == .negative)
  precondition(invalid.value == nil)

  var boolean = ConvertedPartial<BooleanConversion>()
  precondition(parseConverted("true", into: &boolean) == nil)
  precondition(boolean.value == 1)
}

@main
struct EmbeddedSmoke {
  static func main() {
    checkCompletedConversions()
    let payload: StaticString = """
      {"id":4217,"name":"Blob","tags":["a","b"],"active":true,"score":-1.5e2,\
      "address":{"city":"Brooklyn"},"missing":null}
      """

    // A fixed buffer, since the point is a target with no heap to lean on.
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { buffer in
      // Whole, and split at every chunk size that matters. Resumability is where a streaming
      // parser breaks, and it breaks the same way on a microcontroller as anywhere else.
      let whole = parse(payload, chunk: Int.max, buffer: buffer)

      precondition(whole.objects == 2)
      precondition(whole.arrays == 1)
      precondition(whole.keys == 8)
      precondition(whole.strings == 4)
      precondition(whole.numbers == 2)
      precondition(whole.booleans == 1)
      precondition(whole.nulls == 1)

      // Resumability is where a streaming parser breaks, and it breaks the same way on a
      // microcontroller as anywhere else.
      for chunk in [7, 3, 1] {
        let split = parse(payload, chunk: chunk, buffer: buffer)
        precondition(split.objects == whole.objects)
        precondition(split.arrays == whole.arrays)
        precondition(split.keys == whole.keys)
        precondition(split.strings == whole.strings)
        precondition(split.numbers == whole.numbers)
        precondition(split.booleans == whole.booleans)
        precondition(split.nulls == whole.nulls)
        precondition(split.keyWordChecksum == whole.keyWordChecksum)
        precondition(split.stringByteChecksum == whole.stringByteChecksum)
        precondition(split.magnitudeSum == whole.magnitudeSum)
      }

      // The type and its empty storage must still compile and link on the target. Exercising
      // `_openValue` for a new key is intentionally left to the host tests: the current embedded
      // Swift runtime does not provide the Unicode normalization symbols needed to materialize a
      // String from an arbitrary key span.
      let dictionary = StreamDictionary<Int>()
      precondition(dictionary.isEmpty)

      // The partial to whole conversions, both directions of strictness.
      precondition(Reading(streamPartial: 12)?.meters == 12)
      precondition(Reading(streamPartial: nil)?.meters == nil)
      precondition(Reading(orInitial: nil).meters == 0)
      precondition(Reading(orInitial: 12).meters == 12)

      // Absent nests to nil and converts; present but undescribable declines; or-initial fills.
      precondition(Nested(streamPartial: .some(nil))?.inner?.meters == nil)
      precondition(Nested(streamPartial: .some(.some(3)))?.inner?.meters == 3)
      precondition(Nested(streamPartial: .some(.none))?.inner?.meters == nil)
      precondition(Nested(orInitial: nil).inner?.meters == nil)

      // A malformed document has to be rejected here too, not just on Darwin.
      var rejected = false
      withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 128) { scratch in
        var parser = JSONParser(buffer: scratch)
        var sink = SmokeSink()
        let bad: StaticString = #"{"a":1,}"#
        // `try?` rather than a catch: an untyped catch binds `any Error`, which embedded Swift
        // rejects outright. The parser's throws are typed, so nothing is lost.
        bad.withUTF8Buffer { input in
          if (try? parser.parse(input, into: &sink)) == nil {
            rejected = true
            return
          }
          if (try? parser.finish(into: &sink)) == nil {
            rejected = true
          }
        }
      }
      precondition(rejected)
    }
  }
}
