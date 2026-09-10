import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// The `.skip` disposition: a `PartialSink` answers it for a container under an unknown key,
// and the parser scans the subtree structurally instead of parsing it. These tests pin the
// three sides of that contract: values built through skipped neighbors are identical at every
// chunk cut, the loosenesses are exactly the documented ones (token interiors unchecked), and
// everything the skip still validates — bracket kinds, string termination, UTF-8, the depth
// cap — stays rejected.

@StreamParseable
private struct SkipRow: Equatable {
  var id: Int = 0
  var name: String = ""
  var after: Bool = false
}

@Suite
struct ContainerSkipTests {
  private enum Outcome: Equatable {
    case value(id: Int?, name: StreamString?, after: Bool?)
    case parserError(JSONParsingError.Reason)
    case sinkFailure(StreamSinkFailure.Reason)
  }

  private func parse(_ json: String, chunk: Int, windowThreshold: Int = .max) -> Outcome {
    let payload = Array(json.utf8)
    var value = SkipRow.Partial.streamInitialValue()
    var outcome: Outcome?
    withUnsafeMutablePointer(to: &value) { pointer in
      var parser = JSONParser(windowThreshold: windowThreshold)
      var sink = PartialSink(root: pointer)
      do {
        try payload.withUnsafeBufferPointer { input in
          var index = 0
          while index < input.count {
            let end = min(index + chunk, input.count)
            try parser.parse(UnsafeBufferPointer(rebasing: input[index..<end]), into: &sink)
            index = end
          }
        }
        try parser.finish(into: &sink)
      } catch let error as JSONParsingError {
        outcome = .parserError(error.reason)
      } catch {}
      if outcome == nil, let failure = sink.streamFailure {
        outcome = .sinkFailure(failure.reason)
      }
    }
    return outcome ?? .value(id: value.id, name: value.name, after: value.after)
  }

  // Every chunk size that changes which state carries the skip across a boundary, byte-fed
  // included — and the windowed walk, whose open arms honor the skip through their own path.
  private func expectAllChunks(
    _ json: String, _ expected: Outcome, sizes: [Int] = [Int.max, 64, 7, 3, 2, 1]
  ) {
    for chunk in sizes {
      expectNoDifference(self.parse(json, chunk: chunk), expected, "chunk \(chunk)")
    }
    expectNoDifference(
      self.parse(json, chunk: Int.max, windowThreshold: 1), expected, "windowed"
    )
  }

  private static let populated = Outcome.value(id: 7, name: "row", after: true)

  @Test
  func `Values survive around skipped subtrees at every chunk cut`() {
    self.expectAllChunks(
      #"""
      {"id":7,
       "unknown":{"a":[1,2,{"b":"c"}],"d":"é✓ \n \"quoted\" \\ tail","e":null,"f":1.5e-3},
       "name":"row",
       "also unknown":[[[]],{},"",-0.5,true,false,null],
       "after":true}
      """#,
      Self.populated
    )
  }

  @Test
  func `A skipped string carries escapes and UTF-8 across any boundary`() {
    // The backslash, the escaped quote, and a three-byte sequence all land on cut points at
    // some chunk size in the sweep.
    self.expectAllChunks(
      #"{"unknown":{"k":"a\"b\\c héllo ✓ é end"},"id":7,"name":"row","after":true}"#,
      Self.populated
    )
  }

  // The documented looseness: token interiors inside a skipped subtree are not validated.
  // These documents are malformed and would be rejected on any streamed path; under a skipping
  // sink they parse. If this test ever starts failing because the skip got stricter, the
  // documentation on `StreamContainerDisposition.skip` is what has to change with it.
  @Test
  func `Token interiors inside a skipped subtree are not validated`() {
    self.expectAllChunks(#"{"unknown":{"a" 1 2 ,, tru xyz 01.2.3},"id":7,"name":"row","after":true}"#, Self.populated)
    self.expectAllChunks(#"{"unknown":["\q"],"id":7,"name":"row","after":true}"#, Self.populated)
  }

  @Test(arguments: [
    [0xFF], [0x80], [0xC0, 0x80], [0xC2], [0xC2, 0x41],
    [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80],
  ] as [[UInt8]])
  func `A skipped escape does not hide invalid UTF-8`(sequence: [UInt8]) {
    let bytes: [UInt8] = [0x5B, 0x22, 0x5C] + sequence + [0x22, 0x5D]
    for threshold in [Int.max, 1] {
      for split in (0...bytes.count).map(Optional.some) + [nil] {
        let error = #expect(throws: JSONParsingError.self) {
          try self.parseSkipping(bytes, splitAt: split, windowThreshold: threshold)
        }
        expectNoDifference(error, JSONParsingError(reason: .invalidUTF8, byteOffset: 3))
      }
    }
  }

  // Skip mode does not validate escape selectors, but their bytes must still be valid UTF-8.
  // In particular, it must validate the entire scalar rather than discard only its lead byte.
  @Test(arguments: [
    [0xC2, 0x80], [0xDF, 0xBF], [0xE0, 0xA0, 0x80], [0xED, 0x9F, 0xBF],
    [0xF0, 0x90, 0x80, 0x80], [0xF4, 0x8F, 0xBF, 0xBF],
  ] as [[UInt8]])
  func `A skipped non-ASCII escape is validated without emitting its interior`(sequence: [UInt8]) throws {
    let bytes: [UInt8] = [0x5B, 0x22, 0x5C] + sequence + [0x5C, 0x22, 0x22, 0x5D]
    for threshold in [Int.max, 1] {
      for split in (0...bytes.count).map(Optional.some) + [nil] {
        let calls = try self.parseSkipping(bytes, splitAt: split, windowThreshold: threshold)
        expectNoDifference(calls, ["beginArray", "endArray"])
      }
    }
  }

  // nil selects the dedicated byte-fed entry point; otherwise split the buffer in two.
  private func parseSkipping(
    _ bytes: [UInt8], splitAt: Int?, windowThreshold: Int
  ) throws -> [String] {
    var parser = JSONParser(windowThreshold: windowThreshold)
    var sink = RootSkippingSink()
    if let splitAt {
      try bytes.withUnsafeBufferPointer { input in
        try parser.parse(UnsafeBufferPointer(rebasing: input[..<splitAt]), into: &sink)
        try parser.parse(UnsafeBufferPointer(rebasing: input[splitAt...]), into: &sink)
      }
    } else {
      for byte in bytes { try parser.parse(byte: byte, into: &sink) }
    }
    try parser.finish(into: &sink)
    return sink.calls
  }

  // What the skip still rejects, at every chunk cut.
  @Test(arguments: UInt8(0)..<UInt8(32))
  func `A backslash does not hide a raw control byte in a skipped string`(control: UInt8) {
    let json = "{\"unknown\":[\"a\\" + String(UnicodeScalar(control))
      + "b\"],\"id\":7}"
    self.expectAllChunks(
      json, .parserError(.unterminatedString), sizes: Array(1...json.utf8.count)
    )
  }

  @Test
  func `A skipped subtree still validates structure`() {
    // A `[` closed by `}`: the containers bitmap tracks kinds through the skip.
    self.expectAllChunks(
      #"{"unknown":[1,2}],"id":7}"#, .parserError(.unexpectedToken)
    )
    // A raw control byte inside a skipped string.
    self.expectAllChunks(
      "{\"unknown\":\"a\u{01}b\",\"id\":7}", .parserError(.unterminatedString)
    )
    // Invalid UTF-8 (a lone continuation byte) inside a skipped string.
    let invalid = Array(#"{"unknown":""#.utf8) + [0x80] + Array(#"","id":7}"#.utf8)
    for chunk in [Int.max, 3, 1] {
      var value = SkipRow.Partial.streamInitialValue()
      withUnsafeMutablePointer(to: &value) { pointer in
        var parser = JSONParser()
        var sink = PartialSink(root: pointer)
        var reason: JSONParsingError.Reason?
        do {
          try invalid.withUnsafeBufferPointer { input in
            var index = 0
            while index < input.count {
              let end = min(index + chunk, input.count)
              try parser.parse(UnsafeBufferPointer(rebasing: input[index..<end]), into: &sink)
              index = end
            }
          }
          try parser.finish(into: &sink)
        } catch let error as JSONParsingError {
          reason = error.reason
        } catch {}
        expectNoDifference(reason, .invalidUTF8, "chunk \(chunk)")
      }
    }
    // A stray byte outside any token class.
    self.expectAllChunks(#"{"unknown":[#],"id":7}"#, .parserError(.unexpectedToken))
  }

  @Test
  func `The depth cap holds inside a skipped subtree`() {
    let deep = String(repeating: "[", count: 70) + String(repeating: "]", count: 70)
    self.expectAllChunks(#"{"unknown":\#(deep),"id":7}"#, .parserError(.depthExceeded))
  }

  @Test
  func `A document ending mid-skip is unterminated`() {
    self.expectAllChunks(#"{"unknown":{"a":[1,2"#, .parserError(.unterminatedContainer))
    self.expectAllChunks(#"{"unknown":{"a":"cut"#, .parserError(.unterminatedString))
  }

  // A known key whose member cannot hold a container is still the mismatch it always was —
  // the skip is only for subtrees nothing was expecting — and it surfaces at the opening
  // bracket as a rejection, exactly as before.
  @Test
  func `A container at a scalar member still fails, not skips`() {
    self.expectAllChunks(
      #"{"id":{"a":1}}"#,
      .parserError(.sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
    )
  }

  // The advisory half of the contract: through the batching adapter the skip cannot be
  // honored, the interior is delivered into the sink's ignored frame, and the value comes out
  // the same.
  @Test
  func `The batching adapter delivers a skipped-eligible subtree and agrees`() throws {
    let json = #"{"id":7,"unknown":{"a":[1,{"b":"c"}],"d":"é \n tail"},"name":"row","after":true}"#
    let payload = Array(json.utf8)
    var value = SkipRow.Partial.streamInitialValue()
    try withUnsafeMutablePointer(to: &value) { pointer in
      var parser = JSONParser()
      var sink = StreamEventBatchingSink(consumer: SkipReplayConsumer(sink: PartialSink(root: pointer)))
      try payload.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
      try parser.finish(into: &sink)
      sink.commit()
    }
    expectNoDifference(value.id, 7)
    expectNoDifference(value.name, "row")
    expectNoDifference(value.after, true)
  }

  // A sink other than PartialSink skipping at the root: the open and the matching close are
  // the only structural calls it sees, and nothing in between.
  @Test
  func `A root-level skip sees only the open and its close`() throws {
    let json = #"{"a":[1,2,{"b":"c"}],"d":"text"}   "#
    for chunk in [Int.max, 3, 1] {
      var parser = JSONParser()
      var sink = RootSkippingSink()
      let payload = Array(json.utf8)
      try payload.withUnsafeBufferPointer { input in
        var index = 0
        while index < input.count {
          let end = min(index + chunk, input.count)
          try parser.parse(UnsafeBufferPointer(rebasing: input[index..<end]), into: &sink)
          index = end
        }
      }
      try parser.finish(into: &sink)
      expectNoDifference(sink.calls, ["beginObject", "endObject"], "chunk \(chunk)")
    }
  }
}

private struct SkipReplayConsumer: StreamEventBatchConsumer, ~Copyable {
  var sink: PartialSink
  var streamFailure: StreamSinkFailure? { self.sink.streamFailure }
  mutating func events(_ batch: borrowing StreamEventBatch) -> Int {
    batch.replay(into: &self.sink)
  }
}

private struct RootSkippingSink: StreamParseSink {
  var calls: [String] = []
  var streamFailure: StreamSinkFailure? { nil }

  mutating func beginObject() -> StreamContainerDisposition {
    self.calls.append("beginObject")
    return .skip
  }
  mutating func endObject() { self.calls.append("endObject") }
  mutating func beginArray() -> StreamContainerDisposition {
    self.calls.append("beginArray")
    return .skip
  }
  mutating func endArray() { self.calls.append("endArray") }
  mutating func key(_ bytes: Span<UInt8>) { self.calls.append("key") }
  mutating func stringBegin() { self.calls.append("stringBegin") }
  mutating func stringChunk(_ bytes: Span<UInt8>) { self.calls.append("stringChunk") }
  mutating func stringEnd() { self.calls.append("stringEnd") }
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) { self.calls.append("number") }
  mutating func boolean(_ value: Bool) { self.calls.append("boolean") }
  mutating func null() { self.calls.append("null") }
}
