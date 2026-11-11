import CustomDump
import Foundation
import StreamParsing
import StreamParsingCore
import Testing

// MARK: - 5. Text fidelity
//
// Strings are where streaming parsers most often go subtly wrong: escapes and multi-byte scalars
// cut by a chunk boundary, invalid UTF-8 that is only caught when it arrives in one piece. These
// are synthetic on purpose -- each row is one precise byte-level edge.

@StreamParseable
struct TextHolder: Equatable {
  var text: String
}

private func holder(_ body: String) -> [UInt8] { Array(#"{"text":"\#(body)"}"#.utf8) }

@Suite
struct `Text fidelity` {
  // TX-1
  // Every escape form, and every UTF-8 width, at every possible cut: the decoded string is exact.
  @Test(arguments: [
    (#"\"\\\/\b\f\n\r\t"#, "\"\\/\u{8}\u{C}\n\r\t"),
    (#"\u0000\u001f\u007F"#, "\u{0}\u{1F}\u{7F}"),
    (#"éé€￿"#, "éé€\u{FFFF}"),
    (#"😀𝄞"#, "😀𝄞"),
    ("Aé€😀", "Aé€😀"),  // raw 1-, 2-, 3- and 4-byte UTF-8
    (#"xéé😀😀\n"#, "xéé😀😀\n"),  // escaped and raw interleaved
  ])
  func `Every escape and UTF-8 width decodes exactly at every cut`(body: String, expected: String)
    throws
  {
    let bytes = holder(body)
    let whole = try parse(bytes, as: TextHolder.self)
    #expect(whole.text.map(String.init) == expected)
    for cut in 1..<bytes.count {
      var stream = PartialsStream<TextHolder>(from: .json())
      try stream.next(bytes[..<cut])
      try stream.next(bytes[cut...])
      let value = try stream.finishPartial()
      #expect(value.text.map(String.init) == expected, "cut at \(cut)")
    }
    let byteFed = try parse(bytes, as: TextHolder.self, chunking: .fixed(1))
    #expect(byteFed.text.map(String.init) == expected)
  }

  // TX-2
  // Ill-formed UTF-8 is rejected wherever the boundary falls, at the same byte: the cases a
  // per-chunk validator misses are exactly the ones split across chunks.
  @Test(arguments: [
    ([0xC0, 0xAF], "overlong two-byte"),
    ([0xE0, 0x80, 0xAF], "overlong three-byte"),
    ([0xED, 0xA0, 0x80], "UTF-16 surrogate code point"),
    ([0xF4, 0x90, 0x80, 0x80], "past U+10FFFF"),
    ([0xF5, 0x80, 0x80, 0x80], "invalid lead byte"),
    ([0x80], "lone continuation byte"),
    ([0xE2, 0x82], "truncated before the closing quote"),
    ([0xF0, 0x9F, 0x98, 0x41], "a three-of-four sequence ended by ASCII"),
  ] as [([UInt8], String)])
  func `Ill-formed UTF-8 is rejected at the same byte at every cut`(
    sequence: [UInt8], label: String
  ) throws {
    let bytes = Array(#"{"text":"ok "#.utf8) + sequence + Array(#" ok"}"#.utf8)
    let expected = try #require(rawParsingError(bytes), "\(label) was accepted")
    #expect(expected.reason == .invalidUTF8)
    for cut in 1..<bytes.count {
      let chunks = [Array(bytes[..<cut]), Array(bytes[cut...])]
      var sink = TreeSink()
      var parser = JSONParser()
      var actual: JSONParsingError?
      do {
        for chunk in chunks { try chunk.withUnsafeBufferPointer { try parser.parse($0, into: &sink) } }
        try parser.finish(into: &sink)
      } catch let error as JSONParsingError {
        actual = error
      }
      #expect(actual == expected, "\(label), cut at \(cut)")
    }
    expectNoDifference(parsingError(bytes, as: TextHolder.self, chunking: .fixed(1)), expected)
  }

  // TX-3
  // A surrogate escape must be a well-formed pair; a lone half is not text.
  @Test(arguments: [
    #"\ud83d"#, #"\ude00"#, #"\ud83dA"#, #"\ud83dx"#, #"\ud83d\ud83d"#, #"\ude00\ud83d"#,
  ])
  func `Unpaired surrogate escapes are rejected`(body: String) {
    let bytes = holder(body)
    #expect(rawParsingError(bytes) != nil, "\(body)")
    #expect(rawParsingError(bytes, chunking: .fixed(1)) != nil, "\(body) byte by byte")
  }

  // TX-4
  // RFC 8259 requires control characters to be escaped inside strings; a raw one is an error,
  // in a value and in a key.
  @Test(arguments: Array(UInt8(0x00)...UInt8(0x1F)))
  func `Unescaped control characters in strings are rejected`(byte: UInt8) {
    let inValue = Array(#"{"text":"a"#.utf8) + [byte] + Array(#"b"}"#.utf8)
    let inKey = Array(#"{"a"#.utf8) + [byte] + Array(#"b":1}"#.utf8)
    #expect(rawParsingError(inValue) != nil)
    #expect(rawParsingError(inValue, chunking: .fixed(1)) != nil)
    #expect(rawParsingError(inKey) != nil)
  }
}
