import CustomDump
import Testing

import StreamParsingCore

// The guarantee `StringInfo.Flags.validatedUTF8` rests on: every span `JSONParser` hands a sink as
// a string value is well-formed UTF-8 on its own, before the parser has decided whether the
// document is. `PartialsStream` vouches for it, and `String` copies such a span in unchecked, so a
// span that broke it would be a `String` with broken invariants, not a wrong value. Swept over
// documents that are mostly invalid -- bad bytes, cut sequences, lone surrogates -- at every chunk
// shape, with a buffer small enough to flush the coalesced escape path mid-string.

// A xorshift, so the sweep is the same on every machine and every run.
private struct SweepGenerator: RandomNumberGenerator {
  var state: UInt64 = 0x2026_1015_0D7F_8A11

  mutating func next() -> UInt64 {
    self.state ^= self.state << 13
    self.state ^= self.state >> 7
    self.state ^= self.state << 17
    return self.state
  }
}

// Checks each string span on its own, and counts what it checked so the sweep cannot pass empty.
private struct UTF8CheckingSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  var spans = 0
  var illFormed: [[UInt8]] = []

  mutating func check(_ bytes: Span<UInt8>) {
    let copy = streamCopy(bytes)
    self.spans += 1
    // The repairing decode changes exactly the bytes that are not well-formed UTF-8.
    if Array(String(decoding: copy, as: UTF8.self).utf8) != copy { self.illFormed.append(copy) }
  }

  mutating func beginObject() -> StreamContainerDisposition { .stream }
  mutating func endObject() {}
  mutating func beginArray() -> StreamContainerDisposition { .stream }
  mutating func endArray() {}
  mutating func key(_ bytes: Span<UInt8>) { self.check(bytes) }
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) { self.check(bytes) }
  mutating func stringEnd() {}
  mutating func string(_ bytes: Span<UInt8>) { self.check(bytes) }
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {}
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}

// What a string's content is built from: well-formed text of every width, escapes that decode to
// it, and each way a byte sequence or an escape can be malformed.
private let pieces: [[UInt8]] = [
  Array("plain ascii text ".utf8), Array("é".utf8), Array("€".utf8), Array("😀".utf8),
  Array(#"\n"#.utf8), Array(#"\""#.utf8), Array(#"é"#.utf8), Array(#"😀"#.utf8),
  Array(String(repeating: "x", count: 40).utf8), Array(String(repeating: "é", count: 20).utf8),
  // Malformed: a lone continuation, an overlong, an encoded surrogate, a byte past U+10FFFF's
  // leads, a two-, three- and four-byte sequence cut short, and lone or doubled surrogate escapes.
  [0x80], [0xC0, 0x80], [0xED, 0xA0, 0x80], [0xF5, 0x80, 0x80, 0x80], [0xC3], [0xE2, 0x82],
  [0xF0, 0x9F, 0x98], Array(#"\uD83D"#.utf8), Array(#"\uDE00"#.utf8), Array(#"\uD83Dx"#.utf8),
  Array(#"\uD83D\uD83D"#.utf8),
]

@Suite
struct `String UTF-8 guarantee tests` {
  @Test
  func `Every string span the parser delivers is well-formed UTF-8 on its own`() {
    var generator = SweepGenerator()
    var spans = 0
    var rejected = 0
    for _ in 0..<400 {
      var document = Array(#"[""#.utf8)
      for _ in 0..<Int.random(in: 1...8, using: &generator) {
        document += pieces.randomElement(using: &generator)!
      }
      document += Array(#"",{"k":""#.utf8)
      for _ in 0..<Int.random(in: 1...4, using: &generator) {
        document += pieces.randomElement(using: &generator)!
      }
      document += Array(#""}]"#.utf8)

      var shapes: [(chunk: Int, buffer: Int)] = [(.max, 4096), (.max, 16)]
      for chunk in [1, 2, 3, 5, 7, 13] { shapes.append((chunk, 16)) }
      for shape in shapes {
        var sink = UTF8CheckingSink()
        do {
          try feed(document, chunk: shape.chunk, into: &sink, bufferCapacity: shape.buffer)
        } catch {
          rejected += 1
        }
        expectNoDifference(sink.illFormed, [], "\(document) chunk \(shape.chunk) buffer \(shape.buffer)")
        spans += sink.spans
      }
      var byByte = UTF8CheckingSink()
      do { try feedByByte(document, into: &byByte, bufferCapacity: 16) } catch { rejected += 1 }
      expectNoDifference(byByte.illFormed, [], "\(document) byte by byte")
      spans += byByte.spans
    }
    // Both halves of the sweep ran: spans were checked, and many documents were refused after
    // delivering some of them.
    #expect(spans > 10_000)
    #expect(rejected > 1_000)
  }
}
