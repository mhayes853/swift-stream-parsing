import Foundation
import Testing

import StreamParsingCore

// Adversarial corpus in the spirit of nst/JSONTestSuite, written inline rather than vendored.
// Each case is also parsed one byte at a time, because a parser that only rejects malformed
// input when it sees it whole is not actually rejecting it.
@Suite
struct `JSON conformance tests` {
  private static func parse(_ bytes: [UInt8], chunk: Int) throws {
    var parser = JSONParser()
    var sink = CountingConformanceSink()
    try bytes.withUnsafeBufferPointer { buffer in
      var i = 0
      while i < buffer.count {
        let count = min(chunk, buffer.count - i)
        let slice = UnsafeBufferPointer(start: buffer.baseAddress! + i, count: count)
        try parser.parse(slice, into: &sink)
        i += count
      }
    }
    try parser.finish(into: &sink)
  }

  private static func expectRejected(_ json: String, _ sourceLocation: SourceLocation = #_sourceLocation) {
    let bytes = Array(json.utf8)
    for chunk in [Int.max, 1] {
      var threw = false
      do {
        try Self.parse(bytes, chunk: chunk)
      } catch {
        threw = true
      }
      if !threw {
        Issue.record(
          "Accepted \(json.debugDescription) at chunk \(chunk == .max ? "whole" : "1")",
          sourceLocation: sourceLocation
        )
        return
      }
    }
  }

  private static func expectAccepted(_ json: String, _ sourceLocation: SourceLocation = #_sourceLocation) {
    let bytes = Array(json.utf8)
    for chunk in [Int.max, 1] {
      do {
        try Self.parse(bytes, chunk: chunk)
      } catch {
        Issue.record(
          "Rejected \(json.debugDescription) at chunk \(chunk == .max ? "whole" : "1"): \(error)",
          sourceLocation: sourceLocation
        )
        return
      }
    }
  }

  // MARK: - Structure

  @Test(arguments: [
    "", " ", "\n", "[", "]", "{", "}", "[,", "{,", "[}", "{]",
    "[1", "{\"a\"", "{\"a\":", "{\"a\":1", "{\"a\":1,", "[1,", "[1,,2]",
    "{\"a\":1}\u{7D}", "[1]]", "[[]", "{}}", "{\"a\"}", "{\"a\",\"b\"}",
    "{1:2}", "{true:1}", "[:]", "[1:2]", "{\"a\"::1}", "{\"a\":1,,\"b\":2}",
    "[1,]", "{\"a\":1,}", "[,1]", "{,\"a\":1}",
  ])
  func `Rejects malformed structure`(json: String) {
    Self.expectRejected(json)
  }

  @Test(arguments: ["0]", "true]", "null]]", #""value"]"#])
  func `Rejects an array close after a root scalar`(json: String) {
    Self.expectRejected(json)
  }

  @Test(arguments: ["{}", "[]", "[[]]", "{\"a\":{}}", "[{},{}]", " [ ] ", "\n\t[]\r\n"])
  func `Accepts well formed structure`(json: String) {
    Self.expectAccepted(json)
  }

  // Whitespace is not scanned ahead of a structural byte, it is discovered by reaching the arm
  // that rejects unrecognised ones, so every state has to recognise it separately and each of the
  // four bytes has to be recognised in each. Trailing whitespace is the one that is easiest to
  // lose: it is the only thing `.done` ever legally sees.
  @Test(arguments: [" ", "\t", "\n", "\r", " \t\r\n ", String(repeating: " ", count: 40)])
  func `Accepts whitespace in every position it may appear`(ws: String) {
    Self.expectAccepted("\(ws){\(ws)\"a\"\(ws):\(ws)1\(ws),\(ws)\"b\"\(ws):\(ws)[\(ws)2\(ws)]\(ws)}\(ws)")
    Self.expectAccepted("\(ws)[\(ws)]\(ws)")
    Self.expectAccepted("\(ws)true\(ws)")
  }

  // A byte below 0x20 that is not one of the four is not whitespace, and reaching the same arm
  // must still reject it rather than skipping it.
  @Test(arguments: ["\u{01}", "\u{0B}", "\u{0C}", "\u{1F}"])
  func `Rejects control bytes that are not whitespace`(control: String) {
    Self.expectRejected("\(control){\"a\":1}")
    Self.expectRejected("{\(control)\"a\":1}")
    Self.expectRejected("{\"a\"\(control):1}")
    Self.expectRejected("{\"a\":1}\(control)")
  }

  @Test(arguments: ["", " ", "\t\n", "   \r\n   "])
  func `Rejects a document that is only whitespace`(json: String) {
    Self.expectRejected(json)
  }

  // MARK: - Numbers

  @Test(arguments: [
    "01", "-01", "007", "1.", "-1.", ".5", "-.5", "1e", "1e+", "1e-", "1.e5",
    "-", "+1", "1..2", "1e5e5", "1.2.3", "0x10", "Infinity", "NaN", "1_000",
    "--1", "1-", "1+", "e5", ".e5",
  ])
  func `Rejects malformed numbers`(json: String) {
    Self.expectRejected(json)
  }

  @Test(arguments: [
    "0", "-0", "1", "-1", "1.0", "-1.0", "0.5", "1e5", "1E5", "1e+5", "1e-5",
    "1.5e10", "-1.5e-10", "123456789012345678901234567890", "0.0000001",
  ])
  func `Accepts well formed numbers`(json: String) {
    Self.expectAccepted(json)
  }

  // MARK: - Strings and escapes

  @Test(arguments: [
    "\"", "\"abc", "\"\\\"", "\"\\", "\"\\x\"", "\"\\u\"", "\"\\u12\"", "\"\\u12g4\"",
    "\"\\uD800\"", "\"\\uD800abc\"", "\"\\uDC00\"",
  ])
  func `Rejects malformed strings`(json: String) {
    Self.expectRejected(json)
  }

  @Test
  func `Rejects raw control bytes in strings`() {
    for byte in UInt8(0)...UInt8(0x1F) {
      let json = "\"a\(Character(UnicodeScalar(byte)))b\""
      Self.expectRejected(json)
    }
  }

  @Test(arguments: [
    "\"\"", "\"abc\"", "\"\\\"\"", "\"\\\\\"", "\"\\/\"", "\"\\b\\f\\n\\r\\t\"",
    "\"\\u0041\"", "\"\\u00e9\"", "\"\\u20ac\"", "\"\\ud83d\\ude00\"", "\"é€😀\"",
  ])
  func `Accepts well formed strings`(json: String) {
    Self.expectAccepted(json)
  }

  // MARK: - Literals

  @Test(arguments: [
    "tru", "truex", "TRUE", "True", "fals", "falsee", "FALSE", "nul", "nulll", "NULL", "None",
  ])
  func `Rejects malformed literals`(json: String) {
    Self.expectRejected(json)
  }

  @Test(arguments: ["true", "false", "null"])
  func `Accepts well formed literals`(json: String) {
    Self.expectAccepted(json)
  }

  // MARK: - UTF-8

  @Test
  func `Rejects invalid UTF-8 in strings`() {
    let invalid: [[UInt8]] = [
      [0x22, 0x80, 0x22],              // lone continuation
      [0x22, 0xC0, 0x80, 0x22],        // overlong two byte
      [0x22, 0xC2, 0x22],              // truncated two byte
      [0x22, 0xE0, 0x80, 0x80, 0x22],  // overlong three byte
      [0x22, 0xF5, 0x80, 0x80, 0x80, 0x22],  // beyond U+10FFFF
      [0x22, 0xFF, 0x22],              // never valid
    ]
    // Byte by byte as well as whole, like every other case: these were the only rejection cases
    // not split, and the split was exactly where the pending sequence path accepted them.
    for bytes in invalid {
      for chunk in [Int.max, 1] {
        #expect(
          throws: (any Error).self,
          "Invalid UTF-8 \(bytes.map { String($0, radix: 16) }) at chunk \(chunk == .max ? "whole" : "1")"
        ) {
          try Self.parse(bytes, chunk: chunk)
        }
      }
    }
  }

  // MARK: - Depth

  @Test
  func `Rejects nesting beyond the container stack`() {
    Self.expectRejected(String(repeating: "[", count: 70) + String(repeating: "]", count: 70))
  }

  @Test
  func `Accepts nesting up to the container stack`() {
    Self.expectAccepted(String(repeating: "[", count: 64) + String(repeating: "]", count: 64))
  }

  // MARK: - Trailing content

  @Test(arguments: ["{} {}", "[] []", "1 2", "true false", "null null", "\"a\" \"b\""])
  func `Rejects trailing content`(json: String) {
    Self.expectRejected(json)
  }
}

struct CountingConformanceSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?

  mutating func beginObject() -> StreamContainerDisposition { .stream }
  mutating func endObject() {}
  mutating func beginArray() -> StreamContainerDisposition { .stream }
  mutating func endArray() {}
  mutating func key(_ bytes: Span<UInt8>) {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {}
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}
