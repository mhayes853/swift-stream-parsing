import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// Cases aimed at the seams the existing corpus does not cover: escapes at the start of a key,
// invalid UTF-8 split across chunk boundaries, and surrogate escape sequences that are almost
// pairs. Every expectation states what a correct parser should do, so a failure here is a bug
// being reported rather than behaviour being pinned.
//
// JSON escape sequences are built from an explicit backslash constant so the source reads
// unambiguously as bytes handed to the parser.
private let esc = "\u{5C}"

@Suite
struct `Adversarial conformance tests` {
  private static func parse(_ bytes: [UInt8], splitAt: Int) throws {
    var parser = JSONParser()
    var sink = CountingConformanceSink()
    try bytes.withUnsafeBufferPointer { buffer in
      let first = UnsafeBufferPointer(start: buffer.baseAddress, count: splitAt)
      let second = UnsafeBufferPointer(
        start: buffer.baseAddress! + splitAt, count: buffer.count - splitAt
      )
      if !first.isEmpty { try parser.parse(first, into: &sink) }
      if !second.isEmpty { try parser.parse(second, into: &sink) }
    }
    try parser.finish(into: &sink)
  }

  private static func parseBytewise(_ bytes: [UInt8]) throws {
    var parser = JSONParser()
    var sink = CountingConformanceSink()
    for byte in bytes {
      try parser.parse(byte: byte, into: &sink)
    }
    try parser.finish(into: &sink)
  }

  private static func expectRejectedAtEverySplit(
    _ bytes: [UInt8], _ sourceLocation: SourceLocation = #_sourceLocation
  ) {
    for split in 0...bytes.count {
      let error = #expect(
        throws: (any Error).self,
        "\(bytes.map { String($0, radix: 16) }) split at \(split)",
        sourceLocation: sourceLocation
      ) {
        try Self.parse(bytes, splitAt: split)
      }
      // One accepted split is the finding; the rest would repeat it.
      guard error != nil else { return }
    }
    #expect(
      throws: (any Error).self,
      "\(bytes.map { String($0, radix: 16) }) byte by byte",
      sourceLocation: sourceLocation
    ) {
      try Self.parseBytewise(bytes)
    }
  }

  private static func expectAcceptedAtEverySplit(
    _ bytes: [UInt8], _ sourceLocation: SourceLocation = #_sourceLocation
  ) {
    for split in 0...bytes.count {
      #expect(
        throws: Never.self,
        "\(bytes.map { String($0, radix: 16) }) split at \(split)",
        sourceLocation: sourceLocation
      ) {
        try Self.parse(bytes, splitAt: split)
      }
    }
    #expect(
      throws: Never.self,
      "\(bytes.map { String($0, radix: 16) }) byte by byte",
      sourceLocation: sourceLocation
    ) {
      try Self.parseBytewise(bytes)
    }
  }

  // MARK: - Keys that begin with an escape

  @Test(arguments: [
    "{\"\(esc)u0041\": 1}",
    "{\"\(esc)n\": 1}",
    "{\"\(esc)t\": 1}",
    "{\"\(esc)\(esc)\": 1}",
    "{\"\(esc)\"\": 1}",
    "{\"\(esc)ud83d\(esc)ude00\": 1}",
  ])
  func `Accepts a key whose first character is an escape`(json: String) {
    Self.expectAcceptedAtEverySplit(Array(json.utf8))
  }

  @Test
  func `Routes a key whose first character is an escape`() throws {
    var counts = StreamDictionary<Int>()
    try parsePartial("{\"\(esc)u0041\": 1, \"b\": 2}", into: &counts)
    expectNoDifference(counts["A"], 1)
    expectNoDifference(counts["b"], 2)
  }

  @Test
  func `Routes a key with an escape in the middle`() throws {
    var counts = StreamDictionary<Int>()
    try parsePartial("{\"a\(esc)nb\": 1}", into: &counts)
    expectNoDifference(counts["a\nb"], 1)
  }

  // MARK: - Invalid UTF-8 across chunk boundaries

  @Test
  func `Rejects invalid UTF-8 at every split position`() {
    let invalid: [[UInt8]] = [
      [0x22, 0x80, 0x22],                    // lone continuation
      [0x22, 0xC0, 0x80, 0x22],              // overlong two byte
      [0x22, 0xC1, 0xBF, 0x22],              // overlong two byte, upper edge
      [0x22, 0xE0, 0x80, 0x80, 0x22],        // overlong three byte
      [0x22, 0xED, 0xA0, 0x80, 0x22],        // UTF-8 encoded surrogate
      [0x22, 0xF0, 0x80, 0x80, 0x80, 0x22],  // overlong four byte
      [0x22, 0xF4, 0x90, 0x80, 0x80, 0x22],  // beyond U+10FFFF
      [0x22, 0xF5, 0x80, 0x80, 0x80, 0x22],  // invalid lead
      [0x22, 0xC3, 0x22, 0x78, 0x22],        // truncated lead swallowing the closing quote
    ]
    for bytes in invalid {
      Self.expectRejectedAtEverySplit(bytes)
    }
  }

  @Test
  func `Accepts valid UTF-8 at every split position`() {
    let valid: [[UInt8]] = [
      Array("\"é\"".utf8),
      Array("\"€\"".utf8),
      Array("\"😀\"".utf8),
      Array("\"aé€😀b\"".utf8),
    ]
    for bytes in valid {
      Self.expectAcceptedAtEverySplit(bytes)
    }
  }

  // MARK: - Surrogate escape sequences

  @Test(arguments: [
    // High, high, low: the first high surrogate is lone.
    "\"\(esc)uD800\(esc)uD800\(esc)uDC00\"",
    // An escape between the pair makes the high surrogate lone.
    "\"\(esc)uD800\(esc)n\(esc)uDC00\"",
    // Reversed pair.
    "\"\(esc)uDC00\(esc)uD800\"",
  ])
  func `Rejects surrogate escapes that do not form a pair`(json: String) {
    Self.expectRejectedAtEverySplit(Array(json.utf8))
  }

  @Test(arguments: [
    "\"\(esc)uD800\(esc)uDC00\"",
    "\"\(esc)uDBFF\(esc)uDFFF\"",
  ])
  func `Accepts surrogate pairs`(json: String) {
    Self.expectAcceptedAtEverySplit(Array(json.utf8))
  }

  @Test
  func `A lone high surrogate is rejected in its own token`() {
    let json = Array("[\"\(esc)uD83D\",\"\(esc)uDE00\"]".utf8)
    let error = #expect(throws: JSONParsingError.self) {
      var parser = JSONParser()
      var sink = CountingConformanceSink()
      try json.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
      try parser.finish(into: &sink)
    }
    expectNoDifference(error?.reason, .invalidEscape)
    // The closing quote of the *first* string, not somewhere in the second.
    expectNoDifference(error?.byteOffset, 8)
  }

}
