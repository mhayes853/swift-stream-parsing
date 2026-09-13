import CustomDump
import Foundation
import Testing

import StreamParsing
import StreamParsingCore

// The skipped interior's 64-byte block path (JSONParserSkip.swift) against the per-byte loop it
// replaces. The scalar loop is the reference: a chunk of fewer than 64 bytes can never enter the
// block path, so parsing the same document at chunk 63 — and byte by byte — is an oracle that
// runs the old code, and every wider chunking has to agree with it exactly: the same sink calls
// in the same order, and the same error, with the same reason and the same byte offset.
//
// The documents are swept across the block grid by padding the skipped interior, so every feature
// below lands at every alignment, including on the 63/64/65 boundaries: escaped quotes, backslash
// runs of odd and even length, non-ASCII sequences, strings longer than a block, control bytes and
// invalid UTF-8 inside skipped strings, stray bytes outside them, and mismatched brackets.
@Suite
struct SkipBlockScanTests {
  // MARK: - The probe

  // Streams down to `skipFromDepth` and skips every container at or below it, recording every
  // call it receives. String content is accumulated rather than recorded per chunk, because how a
  // string value is cut into `stringChunk` calls is a property of the chunking and not of the
  // skip.
  private struct ProbeSink: StreamParseSink {
    let skipFromDepth: Int
    var calls = [String]()
    private var depth = 0
    private var pending = [UInt8]()

    init(skipFromDepth: Int) {
      self.skipFromDepth = skipFromDepth
    }

    mutating func beginObject() -> StreamContainerDisposition {
      self.calls.append("{")
      self.depth &+= 1
      return self.depth >= self.skipFromDepth ? .skip : .stream
    }

    mutating func endObject() {
      self.calls.append("}")
      self.depth &-= 1
    }

    mutating func beginArray() -> StreamContainerDisposition {
      self.calls.append("[")
      self.depth &+= 1
      return self.depth >= self.skipFromDepth ? .skip : .stream
    }

    mutating func endArray() {
      self.calls.append("]")
      self.depth &-= 1
    }

    mutating func key(_ bytes: Span<UInt8>) {
      self.calls.append("key:\(Self.text(bytes))")
    }

    mutating func stringBegin() {
      self.pending.removeAll(keepingCapacity: true)
    }

    mutating func stringChunk(_ bytes: Span<UInt8>) {
      for index in 0..<bytes.count { self.pending.append(bytes[index]) }
    }

    mutating func stringEnd() {
      self.calls.append("str:\(String(decoding: self.pending, as: UTF8.self))")
      self.pending.removeAll(keepingCapacity: true)
    }

    mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
      self.calls.append("num:\(Self.text(bytes))")
    }

    mutating func boolean(_ value: Bool) {
      self.calls.append("bool:\(value)")
    }

    mutating func null() {
      self.calls.append("null")
    }

    var streamFailure: StreamSinkFailure? { nil }

    private static func text(_ bytes: Span<UInt8>) -> String {
      var out = [UInt8]()
      out.reserveCapacity(bytes.count)
      for index in 0..<bytes.count { out.append(bytes[index]) }
      return String(decoding: out, as: UTF8.self)
    }
  }

  private struct Outcome: Equatable {
    var calls: [String]
    var error: JSONParsingError?
  }

  // `chunk == nil` selects the dedicated byte-fed entry point, which drives one byte through the
  // dispatcher at a time and so can never reach the block path either.
  private static func run(
    _ bytes: [UInt8], chunk: Int?, skipFromDepth: Int, windowThreshold: Int = .max
  ) -> Outcome {
    var parser = JSONParser(windowThreshold: windowThreshold)
    var sink = ProbeSink(skipFromDepth: skipFromDepth)
    var error: JSONParsingError?
    do {
      if let chunk {
        try bytes.withUnsafeBufferPointer { input in
          var index = 0
          while index < input.count {
            let end = Swift.min(index &+ chunk, input.count)
            try parser.parse(UnsafeBufferPointer(rebasing: input[index..<end]), into: &sink)
            index = end
          }
        }
      } else {
        for byte in bytes { try parser.parse(byte: byte, into: &sink) }
      }
      try parser.finish(into: &sink)
    } catch let failure as JSONParsingError {
      error = failure
    } catch {}
    return Outcome(calls: sink.calls, error: error)
  }

  // Every chunking has to reproduce the scalar loop's answer. Chunk 63 is the oracle for the
  // larger documents: the block path needs 64 bytes in one call and so never runs.
  private static func expectAgreement(
    _ bytes: [UInt8],
    _ label: @autoclosure () -> String,
    chunks: [Int?] = [nil, 1, 7, 63, 64, 65, 66, 127, 1000, .max],
    depths: [Int] = [1, 2],
    windowed: Bool = true
  ) {
    for depth in depths {
      let expected = Self.run(bytes, chunk: 63, skipFromDepth: depth)
      for chunk in chunks {
        let actual = Self.run(bytes, chunk: chunk, skipFromDepth: depth)
        if actual != expected {
          expectNoDifference(
            actual, expected, "\(label()) depth \(depth) chunk \(chunk.map(String.init) ?? "byte)")"
          )
        }
      }
      if windowed {
        let actual = Self.run(bytes, chunk: .max, skipFromDepth: depth, windowThreshold: 1)
        if actual != expected {
          expectNoDifference(actual, expected, "\(label()) depth \(depth) windowed")
        }
      }
    }
  }

  // MARK: - The swept corpus

  // Everything the block path has to get right, each one placed at every offset modulo the
  // 64-byte grid by the pad in front of it.
  private static let interiors: [(name: String, bytes: [UInt8])] = {
    var cases = [(String, [UInt8])]()
    func add(_ name: String, _ text: String) { cases.append((name, Array(text.utf8))) }
    func add(_ name: String, _ bytes: [UInt8]) { cases.append((name, bytes)) }

    add("plain", #""abc",123,true,false,null,{"x":[1,2,3]}"#)
    add("escaped quote", #""a\"b","c\"","\"""#)
    add("even backslashes", #""a\\","b\\\\","\\\\\\""#)
    add("odd backslashes", #""a\\\"b","\\\"","\\\\\\\"x""#)
    add("backslash then quote", #""\\","\\\\",{"k":"\\"}"#)
    add("loose escape selectors", #""\q\u\n\t","\/""#)
    add("non-ASCII", #""héllo ✓ 𝄞 é","ünïcödé""#)
    add("long string", "\"\(String(repeating: "x", count: 200))\",1")
    add("long non-ASCII string", "\"\(String(repeating: "é✓", count: 60))\",1")
    add("deep nesting", #"{"a":{"b":{"c":[[[1]]]}}},[[[[[[]]]]]]"#)
    add("empty containers", #"{},[],{"a":{}},[[],[]]"#)
    add("numbers", #"1,-2.5e-3,0,1E+10,12345678901234567890"#)
    add("loose literals", #"tru,xyz,nulll,fals"#)
    // Rejections: each has one byte the scalar loop names, and the block path must name it too.
    add("control in string", Array(#""a"#.utf8) + [0x01] + Array(#"b""#.utf8))
    add("escaped control", Array(#""a\"#.utf8) + [0x09] + Array(#"b""#.utf8))
    add("invalid UTF-8 truncated", Array("\"a".utf8) + [0xE2, 0x28] + Array("b\"".utf8))
    add("invalid UTF-8 lone continuation", Array("\"a".utf8) + [0x80] + Array("b\"".utf8))
    add("invalid UTF-8 surrogate", Array("\"a".utf8) + [0xED, 0xA0, 0x80] + Array("b\"".utf8))
    add("invalid UTF-8 overlong", Array("\"a".utf8) + [0xC0, 0x80] + Array("b\"".utf8))
    add("invalid UTF-8 after escape", Array(#""a\"#.utf8) + [0xC2, 0x41] + Array("b\"".utf8))
    add("stray byte", #""a",#,"b""#)
    add("stray backslash", #""a",\,"b""#)
    add("stray uppercase", #""a",TRUE,"b""#)
    add("stray non-ASCII", Array(#""a","#.utf8) + [0xC3, 0xA9] + Array(#","b""#.utf8))
    add("mismatched close", #"[1,2},"a""#)
    add("mismatched close in object", #"{"a":1],"b":2"#)
    add("unterminated string", #""a","b"#)
    add("trailing backslash", #""a","b\"#)
    return cases
  }()

  @Test(arguments: Self.interiors.indices)
  func `Block and scalar skips agree at every alignment`(index: Int) {
    let interior = Self.interiors[index]
    for pad in 0..<70 {
      // Whitespace padding moves the interior across the grid; string padding does the same with
      // the grid falling inside a string instead.
      let spaces = Array(repeating: UInt8(0x20), count: pad)
      let quoted = pad == 0 ? [UInt8]() : Array("\"\(String(repeating: "x", count: pad - 1))\",".utf8)
      for (style, prefix) in [("spaces", spaces), ("string", quoted)] {
        let document =
          Array(#"{"u":["#.utf8) + prefix + interior.bytes + Array(#"],"k":1}"#.utf8)
        Self.expectAgreement(document, "\(interior.name) \(style) pad \(pad)")
      }
    }
  }

  // The same sweep with the interior's own strings straddling the grid: a run of quoted chunks
  // long enough that several blocks fall entirely inside a string, which is the classifier's
  // other speed.
  @Test
  func `Blocks entirely inside a string agree with the scalar loop`() {
    for length in [60, 63, 64, 65, 66, 127, 128, 129, 200] {
      for suffix in ["", "\\\"", "\\\\", "é", "✓", "\\n"] {
        let body = String(repeating: "s", count: length) + suffix
        for pad in [0, 1, 7, 31, 63, 64] {
          let document =
            Array(#"{"u":["#.utf8) + Array(repeating: UInt8(0x20), count: pad)
            + Array("\"\(body)\",\"\(body)\",1".utf8) + Array(#"],"k":1}"#.utf8)
          Self.expectAgreement(document, "length \(length) suffix \(suffix) pad \(pad)")
        }
      }
    }
  }

  // The depth cap's offset has to survive the block path's fallback: a block that could reach it
  // is handed back to the scalar loop, which names the bracket that breached it.
  @Test
  func `The depth cap reports the same byte at every chunking`() {
    for opens in [63, 64, 65, 70, 130] {
      for pad in [0, 1, 33, 64] {
        let document =
          Array(#"{"u":"#.utf8) + Array(repeating: UInt8(0x20), count: pad)
          + Array(String(repeating: "[", count: opens).utf8)
          + Array(String(repeating: "]", count: opens).utf8) + Array(#","k":1}"#.utf8)
        Self.expectAgreement(document, "opens \(opens) pad \(pad)")
      }
    }
  }

  // Truncation at every byte: the carries that cross a chunk boundary are the same ones that
  // cross the end of the document, and every prefix has to fail (or not) identically.
  @Test
  func `Every truncation of a swept document agrees`() {
    let full = Array(
      #"{"u":[{"a":"x\"y\\","b":"héllo ✓","c":[1,2,{"d":null}]},"tail 0123456789"],"k":1}"#.utf8
    )
    for pad in [0, 13, 60, 64, 70] {
      let padded =
        Array(full[0..<6]) + Array(repeating: UInt8(0x20), count: pad) + Array(full[6...])
      for end in 0...padded.count {
        Self.expectAgreement(Array(padded[0..<end]), "pad \(pad) truncated at \(end)")
      }
    }
  }

  // MARK: - Real documents

  @Test(arguments: ["64KB", "512KB", "DeepNested64"])
  func `Resource documents skip identically on both paths`(name: String) throws {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    let bytes = Array(try Data(contentsOf: url))
    // Chunk 63 is the scalar oracle; the rest exercise the block path with every carry shape,
    // including chunk boundaries that land inside strings and inside escapes.
    Self.expectAgreement(
      bytes, name, chunks: [64, 65, 127, 128, 129, 1000, 4096, .max], depths: [1, 2]
    )
  }

  // A skipped subtree that is one long run of blocks, with the close at every offset modulo 64.
  @Test
  func `The matching close is found at every offset in a block`() {
    for filler in 0..<80 {
      let document =
        Array(#"{"u":{"a":"#.utf8) + Array(String(repeating: "1", count: filler + 1).utf8)
        + Array(#"},"k":1}"#.utf8)
      Self.expectAgreement(document, "filler \(filler)")
      let nested =
        Array(#"{"u":[[[["#.utf8) + Array(repeating: UInt8(0x20), count: filler)
        + Array(#"]]]],"k":1}"#.utf8)
      Self.expectAgreement(nested, "nested filler \(filler)")
    }
  }
}
