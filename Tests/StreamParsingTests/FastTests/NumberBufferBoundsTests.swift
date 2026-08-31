import Testing

import StreamParsing
import StreamParsingCore

// Numbers whose token begins near the start of the buffer, where a kernel that reads *backwards*
// from the token's end can run off the front of it.
//
// This suite exists because that defect shipped past 454 passing tests. The short integer kernel
// reads the eight bytes ending at its token and the decimal kernel that was prototyped alongside
// it read sixteen; every unit test for those padded its token with a prefix long enough to make
// the read legal, which is exactly the construction that cannot produce the failing case. The
// parser level tests did place numbers near the buffer start, read out of bounds, and landed in
// memory that happened to be mapped -- no fault, no wrong answer, no signal. Only a release build
// with a different allocation layout segfaulted.
//
// So the property here is deliberately not "the kernel computes the right value". It is "a number
// at *every* offset a document can put one at still parses", driven through the real parser, in
// bulk and byte fed. Any future kernel that reads behind its token is covered by construction.
//
// **This suite only fails under the address sanitizer, and that is not a defect in it.** Mutation
// verified: delete the `to >= 8` bound from the short integer kernel's call site and a plain
// `swift test` stays green -- all 453 of them -- because the out of bounds bytes are masked away
// before they can reach the result, so the read is wrong without the answer being wrong. Under
// `swift test --sanitize=address` the same mutation reports `heap-buffer-overflow` immediately.
// A backward read that lands in mapped memory is invisible to any assertion about values; only a
// sanitizer can see it. Run this suite with ASan, or it proves nothing.

@Suite
struct `Number buffer bounds tests` {
  private static func parse(_ text: String) throws -> [UInt64] {
    var parser = JSONParser()
    var sink = BoundsRecordingSink()
    try Array(text.utf8).withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    try parser.finish(into: &sink)
    return sink.magnitudes
  }

  @Test
  func `A decimal at every offset from the start of a document parses`() throws {
    for padding in 0...24 {
      let key = String(repeating: "a", count: padding)
      let document = padding == 0 ? "[1.5,2.25,300.125]" : "{\"\(key)\":[1.5,2.25,300.125]}"
      #expect(try Self.parse(document) == [15, 225, 300_125], "at padding \(padding)")
    }
  }

  @Test
  func `A bare decimal document parses at the very start of the buffer`() throws {
    #expect(try Self.parse("1.5") == [15])
    #expect(try Self.parse("[0.5]") == [5])
    #expect(try Self.parse("[1]") == [1])
    #expect(try Self.parse("[1.25,3]") == [125, 3])
  }

  // Fed one byte at a time, so every token is reassembled in the parser's own buffer, where the
  // sixteen byte backward read has a different origin again.
  @Test
  func `Byte fed decimals agree with bulk`() throws {
    for document in ["[1.5]", "[0.5,1.25]", "{\"a\":12.345,\"b\":6}", "[1234.5678]"] {
      var bulkParser = JSONParser()
      var bulk = BoundsRecordingSink()
      try Array(document.utf8).withUnsafeBufferPointer { try bulkParser.parse($0, into: &bulk) }
      try bulkParser.finish(into: &bulk)

      var byteParser = JSONParser()
      var byteFed = BoundsRecordingSink()
      for byte in Array(document.utf8) { try byteParser.parse(byte: byte, into: &byteFed) }
      try byteParser.finish(into: &byteFed)

      #expect(bulk.magnitudes == byteFed.magnitudes, "on \(document)")
    }
  }
}

private struct BoundsRecordingSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  var magnitudes: [UInt64] = []

  mutating func beginObject() {}
  mutating func endObject() {}
  mutating func beginArray() {}
  mutating func endArray() {}
  mutating func key(_ bytes: Span<UInt8>) {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.magnitudes.append(info.magnitude)
  }
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}
