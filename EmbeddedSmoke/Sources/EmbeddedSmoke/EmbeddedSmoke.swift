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

  mutating func beginObject() { self.objects &+= 1 }
  mutating func endObject() {}
  mutating func beginArray() { self.arrays &+= 1 }
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

@main
struct EmbeddedSmoke {
  static func main() {
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
