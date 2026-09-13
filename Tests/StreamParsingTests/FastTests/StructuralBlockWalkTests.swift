import CustomDump
import Foundation
import Testing

import StreamParsing
import StreamParsingCore

// The structural run's 64-byte block path (JSONParserBlocks.swift) against the per-byte ladder it
// restates. The scalar loop is the reference, and it is reachable two ways: a chunk of fewer than
// 64 bytes can never enter the block path at all, and `blockWalkEnabled = false` turns it off at
// any chunking. Both are used below — the switch is what makes "the same bytes, the same
// chunking, the two paths" a fair comparison, which is the only comparison that pins the event
// stream exactly (how a string is cut into `stringChunk` calls is a property of the chunking).
//
// Every assertion is on the raw call sequence with the bytes each call carried, plus the error's
// reason and byte offset. Nothing is normalised.
@Suite
struct StructuralBlockWalkTests {
  // MARK: - The probe

  private struct ProbeSink: StreamParseSink {
    var calls = [String]()

    mutating func beginObject() -> StreamContainerDisposition {
      self.calls.append("{")
      return .stream
    }

    mutating func endObject() { self.calls.append("}") }

    mutating func beginArray() -> StreamContainerDisposition {
      self.calls.append("[")
      return .stream
    }

    mutating func endArray() { self.calls.append("]") }

    mutating func key(_ bytes: Span<UInt8>) {
      self.calls.append("key:\(Self.text(bytes))")
    }

    mutating func stringBegin() { self.calls.append("str(") }
    mutating func stringChunk(_ bytes: Span<UInt8>) {
      self.calls.append("chunk:\(Self.text(bytes))")
    }
    mutating func stringEnd() { self.calls.append("str)") }
    mutating func string(_ bytes: Span<UInt8>) {
      self.calls.append("string:\(Self.text(bytes))")
    }

    mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
      self.calls.append(
        "num:\(Self.text(bytes)):\(info.magnitude):\(info.exponent):\(info.digitCount)"
      )
    }

    mutating func boolean(_ value: Bool) { self.calls.append("bool:\(value)") }
    mutating func null() { self.calls.append("null") }

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
    var errorReason: String?
    var errorOffset: Int?
  }

  // `chunk == nil` selects the byte-fed entry point, which can never reach the block path.
  private static func run(
    _ bytes: [UInt8], chunk: Int?, blocks: Bool, rearmGate: Bool = false
  ) -> Outcome {
    var parser = JSONParser()
    parser.blockWalkEnabled = blocks
    var sink = ProbeSink()
    var outcome = Outcome(calls: [], errorReason: nil, errorOffset: nil)
    do {
      if let chunk {
        try bytes.withUnsafeBufferPointer { input in
          var index = 0
          while index < input.count {
            let end = Swift.min(index &+ chunk, input.count)
            // The gate (JSONParserBlocks.swift) is a performance verdict, and on a payload with
            // no whitespace outside its strings it switches the walk off after four blocks --
            // which would leave the corpora below comparing two scalar paths to each other.
            // Clearing it per chunk re-arms the walk every `chunk` bytes, so the differential
            // still covers the whole file rather than its first 256 bytes.
            if rearmGate { parser.blockWalkGivenUp = !parser.blockKernelsAvailable }
            try parser.parse(UnsafeBufferPointer(rebasing: input[index..<end]), into: &sink)
            index = end
          }
          if input.isEmpty { try parser.parse(input, into: &sink) }
        }
      } else {
        for byte in bytes { try parser.parse(byte: byte, into: &sink) }
      }
      try parser.finish(into: &sink)
    } catch let failure as JSONParsingError {
      outcome.errorReason = String(describing: failure.reason)
      outcome.errorOffset = failure.byteOffset
    } catch {
      outcome.errorReason = "unknown"
    }
    outcome.calls = sink.calls
    return outcome
  }

  // The block path off is the oracle, at the same chunking, plus the sub-block chunkings that
  // cannot reach it either way.
  private static func expectAgreement(
    _ bytes: [UInt8],
    _ label: @autoclosure () -> String,
    chunks: [Int?] = [nil, 1, 7, 63, 64, 100, 127, 4096, .max]
  ) {
    for chunk in chunks {
      let expected = Self.run(bytes, chunk: chunk, blocks: false)
      let actual = Self.run(bytes, chunk: chunk, blocks: true)
      if actual != expected {
        expectNoDifference(
          actual, expected, "\(label()) chunk \(chunk.map(String.init) ?? "byte")"
        )
      }
    }
    // The per-byte ladder at chunk 63 is also the oracle for every wider chunking: the document's
    // meaning does not depend on how it is cut. Strings are the one exception (their `stringChunk`
    // calls follow the cuts), so this holds only where the run is clean, which the corpus rows
    // below exercise through the `blocks`-off comparison instead.
  }

  // MARK: - Hand-written shapes

  private static let documents: [(name: String, bytes: [UInt8])] = {
    var cases = [(String, [UInt8])]()
    func add(_ name: String, _ text: String) { cases.append((name, Array(text.utf8))) }
    func add(_ name: String, _ bytes: [UInt8]) { cases.append((name, bytes)) }

    add("flat object", #"{"a":1,"b":"two","c":true,"d":false,"e":null,"f":[1,2,3]}"#)
    add("nested", #"{"a":{"b":{"c":[[[1]]]}},"d":[{"e":[]},{}]}"#)
    add("numbers", #"[1,-2.5e-3,0,1E+10,12345678901234567890,0.5,-0,1e2]"#)
    add("pretty", "{\n  \"a\" : 1 ,\n  \"b\" : [ 1 , 2 ]\n}\n")
    add("escaped values", #"{"a":"x\"y","b":"\\","c":"\u00e9\n\t","d":"plain"}"#)
    add("escaped keys", #"{"a\"b":1,"c\\":2,"\u0041":3}"#)
    add("non-ASCII", #"{"k":"héllo ✓ 𝄞","é":"ünïcödé"}"#)
    add("long string", "{\"k\":\"\(String(repeating: "x", count: 300))\"}")
    add("long non-ASCII", "{\"k\":\"\(String(repeating: "é✓", count: 90))\"}")
    add("long key", "{\"\(String(repeating: "k", count: 200))\":1}")
    add("empty containers", #"[{},[],{"a":{}},[[],[]],""]"#)
    add("string of brackets", #"{"a":"{[,:]}\"","b":"]}"}"#)
    add("tiny", #"1"#)
    add("bare string", #""just a string""#)
    // Error shapes: the byte the scalar ladder names has to be the byte the block path names.
    add("12abc", #"[12abc]"#)
    add("bad literal", #"[tru,1]"#)
    add("bad literal long", #"[truX]"#)
    add("stray byte", #"{"a":#}"#)
    add("stray backslash", #"{"a":\}"#)
    add("uppercase literal", #"[TRUE]"#)
    add("mismatched close", #"[1,2}"#)
    add("mismatched close object", #"{"a":1]"#)
    add("trailing content", #"{"a":1} x"#)
    add("bad number", #"[1.2.3]"#)
    add("leading zero", #"[01]"#)
    add("control in string", Array(#"{"a":"x"#.utf8) + [0x01] + Array(#"y"}"#.utf8))
    add("invalid UTF-8 truncated", Array(#"{"a":"x"#.utf8) + [0xE2, 0x28] + Array(#"y"}"#.utf8))
    add("invalid UTF-8 continuation", Array(#"{"a":"x"#.utf8) + [0x80] + Array(#"y"}"#.utf8))
    add("invalid UTF-8 surrogate", Array(#"{"a":"x"#.utf8) + [0xED, 0xA0, 0x80] + Array(#"y"}"#.utf8))
    add("invalid UTF-8 overlong", Array(#"{"a":"x"#.utf8) + [0xC0, 0x80] + Array(#"y"}"#.utf8))
    add("invalid UTF-8 in key", Array(#"{"k"#.utf8) + [0xC0, 0x80] + Array(#"":1}"#.utf8))
    add("non-ASCII outside string", Array(#"{"a":"#.utf8) + [0xC3, 0xA9] + Array("}".utf8))
    add("unterminated string", #"{"a":"x"#)
    add("unterminated container", #"{"a":[1,2"#)
    add("trailing backslash", #"{"a":"x\"#)
    add("bad escape", #"{"a":"x\qy"}"#)
    add("lone surrogate", #"{"a":"\ud834 "}"#)
    return cases
  }()

  // Each document is swept across the 64-byte grid by padding in front of it, so every feature
  // lands at every alignment — including strings, numbers, literals and escapes cut by a block
  // edge, and block edges falling inside strings.
  @Test(arguments: Self.documents.indices)
  func `The block walk and the scalar ladder agree at every alignment`(index: Int) {
    let document = Self.documents[index]
    for pad in 0..<70 {
      let spaces = Array(repeating: UInt8(0x20), count: pad)
      Self.expectAgreement(spaces + document.bytes, "\(document.name) pad \(pad)")
    }
  }

  // The same sweep inside a container, so the padded prefix is real structure rather than
  // leading whitespace: every feature meets the grid after a key, a colon and a comma too.
  @Test(arguments: Self.documents.indices)
  func `The block walk agrees with a structural prefix in front of it`(index: Int) {
    let document = Self.documents[index]
    for pad in [0, 1, 7, 31, 60, 61, 62, 63, 64, 65, 66, 70] {
      let key = Array("{\"\(String(repeating: "p", count: pad))\":".utf8)
      Self.expectAgreement(key + document.bytes + Array("}".utf8), "\(document.name) key \(pad)")
    }
  }

  // Truncation at every byte: a chunk boundary and the end of the document put the same cuts in
  // front of the walk, and every prefix has to fail (or not) identically.
  @Test
  func `Every truncation of a swept document agrees`() {
    let full = Array(
      #"{"a":"x\"y\\","b":"héllo ✓","c":[1,2,{"d":null}],"e":true,"f":12345678901}"#.utf8
    )
    for pad in [0, 13, 60, 63, 64, 70] {
      let padded = Array(repeating: UInt8(0x20), count: pad) + full
      for end in 0...padded.count {
        Self.expectAgreement(Array(padded[0..<end]), "pad \(pad) truncated at \(end)")
      }
    }
  }

  // A string of every length around the block size, at every alignment: the shape that decides
  // whether the extent is settled by the quote bits or handed back to the scalar loop.
  @Test
  func `Strings of every length around the grid agree`() {
    for length in [0, 1, 60, 61, 62, 63, 64, 65, 66, 127, 128, 129, 200] {
      for suffix in ["", "\\\"", "\\\\", "é", "✓", "\\n", "\\u00e9"] {
        let body = String(repeating: "s", count: length) + suffix
        for pad in [0, 1, 7, 31, 62, 63, 64] {
          let document =
            Array(repeating: UInt8(0x20), count: pad)
            + Array("{\"\(body)\":\"\(body)\",\"k\":[\"\(body)\",1]}".utf8)
          Self.expectAgreement(
            document, "length \(length) suffix \(suffix) pad \(pad)",
            chunks: [63, 64, 100, 4096, .max]
          )
        }
      }
    }
  }

  // Numbers and literals cut by the grid at every offset.
  @Test
  func `Tokens cut by a block edge agree`() {
    for pad in 0..<70 {
      let spaces = Array(repeating: UInt8(0x20), count: pad)
      for body in [
        "[12345678901234567890,1]", "[true,false,null]", "[-0.5e-12]", "[1234,5678]",
        "[truX]", "[12abc]", "[1e]", "[nul]",
      ] {
        Self.expectAgreement(
          spaces + Array(body.utf8), "\(body) pad \(pad)", chunks: [63, 64, 100, 4096, .max]
        )
      }
    }
  }

  // The depth cap, with the breaching bracket at every offset modulo the grid.
  @Test
  func `The depth cap reports the same byte at every chunking`() {
    for opens in [63, 64, 65, 70, 130] {
      for pad in [0, 1, 33, 64] {
        let document =
          Array(repeating: UInt8(0x20), count: pad)
          + Array(String(repeating: "[", count: opens).utf8)
          + Array(String(repeating: "]", count: opens).utf8)
        Self.expectAgreement(document, "opens \(opens) pad \(pad)", chunks: [63, 64, 4096, .max])
      }
    }
  }

  // A skipping sink: the block path has to leave the walk at the open whose disposition was
  // `.skip`, with the same skip end depth the ladder would have recorded.
  private struct SkippingProbe: StreamParseSink {
    let skipFromDepth: Int
    var calls = [String]()
    private var depth = 0

    init(skipFromDepth: Int) { self.skipFromDepth = skipFromDepth }

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
    mutating func key(_ bytes: Span<UInt8>) { self.calls.append("key") }
    mutating func stringBegin() {}
    mutating func stringChunk(_ bytes: Span<UInt8>) {}
    mutating func stringEnd() { self.calls.append("str") }
    mutating func string(_ bytes: Span<UInt8>) { self.calls.append("string") }
    mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) { self.calls.append("num") }
    mutating func boolean(_ value: Bool) { self.calls.append("bool") }
    mutating func null() { self.calls.append("null") }
    var streamFailure: StreamSinkFailure? { nil }
  }

  private static func runSkipping(
    _ bytes: [UInt8], chunk: Int, blocks: Bool, skipFromDepth: Int, rearmGate: Bool = false
  ) -> Outcome {
    var parser = JSONParser()
    parser.blockWalkEnabled = blocks
    var sink = SkippingProbe(skipFromDepth: skipFromDepth)
    var outcome = Outcome(calls: [], errorReason: nil, errorOffset: nil)
    do {
      try bytes.withUnsafeBufferPointer { input in
        var index = 0
        while index < input.count {
          let end = Swift.min(index &+ chunk, input.count)
          if rearmGate { parser.blockWalkGivenUp = !parser.blockKernelsAvailable }
          try parser.parse(UnsafeBufferPointer(rebasing: input[index..<end]), into: &sink)
          index = end
        }
      }
      try parser.finish(into: &sink)
    } catch let failure as JSONParsingError {
      outcome.errorReason = String(describing: failure.reason)
      outcome.errorOffset = failure.byteOffset
    } catch {
      outcome.errorReason = "unknown"
    }
    outcome.calls = sink.calls
    return outcome
  }

  @Test
  func `A skipping sink leaves the block walk at the same open`() {
    for pad in 0..<70 {
      let document =
        Array(repeating: UInt8(0x20), count: pad)
        + Array(#"{"a":{"b":[1,2,{"c":"x"}],"d":"y"},"e":[[1],[2]],"f":1}"#.utf8)
      for depth in [1, 2, 3] {
        for chunk in [64, 100, 4096, Int.max] {
          let expected = Self.runSkipping(
            document, chunk: chunk, blocks: false, skipFromDepth: depth
          )
          let actual = Self.runSkipping(document, chunk: chunk, blocks: true, skipFromDepth: depth)
          if actual != expected {
            expectNoDifference(actual, expected, "pad \(pad) depth \(depth) chunk \(chunk)")
          }
        }
      }
    }
  }

  // MARK: - Real documents

  private static let corpusDirectory: URL = {
    var url = URL(fileURLWithPath: #filePath)
    // Tests/StreamParsingTests/FastTests/<this file>
    for _ in 0..<4 { url.deleteLastPathComponent() }
    return
      url
      .appendingPathComponent("Benchmarks")
      .appendingPathComponent("StreamParsingBenchmarks")
      .appendingPathComponent("Resources")
  }()

  @Test(
    arguments: [
      "canada", "citm_catalog", "github_events", "gsoc-2018", "llm_message", "mesh", "twitter",
      "twitterescaped",
    ]
  )
  func `Benchmark corpora parse identically on both paths`(name: String) throws {
    let url = Self.corpusDirectory.appendingPathComponent("\(name).json")
    let bytes = Array(try Data(contentsOf: url))
    for chunk in [64, 100, 4096, Int.max] {
      let expected = Self.run(bytes, chunk: chunk, blocks: false)
      let actual = Self.run(bytes, chunk: chunk, blocks: true)
      #expect(actual.errorReason == expected.errorReason, "\(name) chunk \(chunk)")
      #expect(actual.errorOffset == expected.errorOffset, "\(name) chunk \(chunk)")
      #expect(actual.calls.count == expected.calls.count, "\(name) chunk \(chunk)")
      if actual.calls != expected.calls {
        let first = zip(actual.calls, expected.calls).enumerated().first { $0.element.0 != $0.element.1 }
        Issue.record("\(name) chunk \(chunk) first difference at \(String(describing: first))")
      }
    }
  }

  // The same corpora with the gate held open. Five blocks per chunk is four strikes plus one, so
  // the walk is alive for most of every chunk on `Canada`, `Mesh`, `LLM message` and
  // `Twitter escaped` -- the four the gate exists for, and therefore the four whose block path
  // the test above would otherwise stop exercising after the first 256 bytes.
  @Test(
    arguments: [
      "canada", "citm_catalog", "github_events", "gsoc-2018", "llm_message", "mesh", "twitter",
      "twitterescaped",
    ]
  )
  func `Benchmark corpora agree with the gate held open`(name: String) throws {
    let url = Self.corpusDirectory.appendingPathComponent("\(name).json")
    let bytes = Array(try Data(contentsOf: url))
    for chunk in [320, 4096] {
      let expected = Self.run(bytes, chunk: chunk, blocks: false)
      let actual = Self.run(bytes, chunk: chunk, blocks: true, rearmGate: true)
      #expect(actual.errorReason == expected.errorReason, "\(name) chunk \(chunk)")
      #expect(actual.errorOffset == expected.errorOffset, "\(name) chunk \(chunk)")
      #expect(actual.calls.count == expected.calls.count, "\(name) chunk \(chunk)")
      if actual.calls != expected.calls {
        let first = zip(actual.calls, expected.calls).enumerated()
          .first { $0.element.0 != $0.element.1 }
        Issue.record("\(name) chunk \(chunk) first difference at \(String(describing: first))")
      }
    }
  }

  // The skip that happens *inside* a block (`skipWithinBlock`): every hand-written shape above,
  // at every offset of the 64-byte grid, with a sink that skips from each depth in turn. The
  // scalar ladder -- which always hands a skipped subtree to `consumeSkipRun` -- is the oracle,
  // so this pins the fused skip to the scanner's own contract: the same calls, the matching close
  // delivered at the same byte, the same error reason at the same offset.
  @Test(arguments: Array(Self.documents.indices))
  func `A skipping sink agrees at every alignment`(index: Int) {
    let document = Self.documents[index]
    for pad in [0, 1, 13, 31, 32, 47, 60, 61, 62, 63, 64, 65] {
      let bytes = Array(repeating: UInt8(0x20), count: pad) + document.bytes
      for skipFromDepth in [1, 2, 3, 4] {
        for chunk in [64, 100, 127, 4096, Int.max] {
          let expected = Self.runSkipping(
            bytes, chunk: chunk, blocks: false, skipFromDepth: skipFromDepth
          )
          let actual = Self.runSkipping(
            bytes, chunk: chunk, blocks: true, skipFromDepth: skipFromDepth
          )
          if actual != expected {
            expectNoDifference(
              actual, expected,
              "\(document.name) pad \(pad) skip>=\(skipFromDepth) chunk \(chunk)"
            )
          }
        }
      }
    }
  }

  // The same, over whole corpora: a skipped subtree that outlives its block has to reach
  // `consumeSkipRun` in the state the ladder would have left it in, and these payloads hold
  // thousands of them. The gate is held open so the walk is alive across the whole file.
  @Test(
    arguments: [
      "canada", "citm_catalog", "github_events", "gsoc-2018", "llm_message", "mesh", "twitter",
      "twitterescaped",
    ]
  )
  func `Benchmark corpora agree with a skipping sink`(name: String) throws {
    let url = Self.corpusDirectory.appendingPathComponent("\(name).json")
    let bytes = Array(try Data(contentsOf: url))
    for skipFromDepth in [1, 2, 3] {
      for chunk in [320, 4096, Int.max] {
        let expected = Self.runSkipping(
          bytes, chunk: chunk, blocks: false, skipFromDepth: skipFromDepth
        )
        let actual = Self.runSkipping(
          bytes, chunk: chunk, blocks: true, skipFromDepth: skipFromDepth, rearmGate: true
        )
        #expect(
          actual.errorReason == expected.errorReason,
          "\(name) skip>=\(skipFromDepth) chunk \(chunk)"
        )
        #expect(
          actual.errorOffset == expected.errorOffset,
          "\(name) skip>=\(skipFromDepth) chunk \(chunk)"
        )
        #expect(
          actual.calls.count == expected.calls.count,
          "\(name) skip>=\(skipFromDepth) chunk \(chunk)"
        )
        if actual.calls != expected.calls {
          let first = zip(actual.calls, expected.calls).enumerated()
            .first { $0.element.0 != $0.element.1 }
          Issue.record(
            "\(name) skip>=\(skipFromDepth) chunk \(chunk) at \(String(describing: first))"
          )
        }
      }
    }
  }

  @Test(arguments: ["64KB", "512KB", "DeepNested64"])
  func `Test fixtures parse identically on both paths`(name: String) throws {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    let bytes = Array(try Data(contentsOf: url))
    for chunk in [64, 100, 4096, Int.max] {
      let expected = Self.run(bytes, chunk: chunk, blocks: false)
      let actual = Self.run(bytes, chunk: chunk, blocks: true)
      #expect(actual == expected, "\(name) chunk \(chunk)")
    }
  }
}
