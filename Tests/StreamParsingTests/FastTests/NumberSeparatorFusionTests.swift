import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// The structural run's number arm loops over `number , number` and `number , <space> number`
// inside an array without going back through the ladder. The per-byte path can never take that
// shortcut (a number is cut by every one-byte chunk), so it is the oracle: the same call sequence,
// the same error reason at the same byte, at every chunking. The documents carry no string values,
// whose `stringChunk` cuts follow the chunking; keys are delivered whole and are fine.
@Suite
struct `Number separator fusion tests` {
  private struct ProbeSink: StreamParseSink {
    var calls = [String]()
    // Refuse the n-th number (1-based); zero refuses nothing.
    var refuseNumber = 0
    var numbers = 0
    var failure: StreamSinkFailure?

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
      self.calls.append("key:\(String(decoding: streamCopy(bytes), as: UTF8.self))")
    }

    mutating func stringBegin() { self.calls.append("str(") }
    mutating func stringChunk(_ bytes: Span<UInt8>) { self.calls.append("chunk") }
    mutating func stringEnd() { self.calls.append("str)") }
    mutating func string(_ bytes: Span<UInt8>) { self.calls.append("string") }

    mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
      self.numbers += 1
      if self.numbers == self.refuseNumber {
        self.failure = StreamSinkFailure(reason: .typeMismatch)
        return
      }
      self.calls.append(
        "num:\(String(decoding: streamCopy(bytes), as: UTF8.self)):\(info.magnitude):\(info.exponent):\(info.digitCount):\(info.flags.rawValue)"
      )
    }

    mutating func boolean(_ value: Bool) { self.calls.append("bool:\(value)") }
    mutating func null() { self.calls.append("null") }

    var streamFailure: StreamSinkFailure? { self.failure }
  }

  private struct Outcome: Equatable {
    var calls: [String]
    var errorReason: String?
    var errorOffset: Int?
  }

  // `chunk == nil` is the byte-fed entry point; a positive chunk cuts at that stride; zero or a
  // negative one cuts once, at `-chunk` (zero is an empty first chunk, not a stride of zero).
  private static func run(_ bytes: [UInt8], chunk: Int?, refusing: Int = 0) -> Outcome {
    var parser = JSONParser()
    var sink = ProbeSink()
    sink.refuseNumber = refusing
    var outcome = Outcome(calls: [], errorReason: nil, errorOffset: nil)
    do {
      if let chunk {
        try bytes.withUnsafeBufferPointer { input in
          if chunk <= 0 {
            let split = -chunk
            try parser.parse(UnsafeBufferPointer(rebasing: input[0..<split]), into: &sink)
            try parser.parse(UnsafeBufferPointer(rebasing: input[split...]), into: &sink)
            return
          }
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
      outcome.errorReason = String(describing: failure.reason)
      outcome.errorOffset = failure.byteOffset
    } catch {
      outcome.errorReason = "unknown"
    }
    outcome.calls = sink.calls
    return outcome
  }

  private static func expectAgreement(
    _ text: String,
    refusing: Int = 0,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) {
    let bytes = Array(text.utf8)
    let expected = Self.run(bytes, chunk: nil, refusing: refusing)
    var chunks: [Int] = [1, 2, 3, 5, 7, 63, 64, 100, 4096, .max]
    if bytes.count <= 200 { chunks += (0...bytes.count).map { -$0 } }
    for chunk in chunks {
      let actual = Self.run(bytes, chunk: chunk, refusing: refusing)
      if actual != expected {
        expectNoDifference(
          actual, expected, "\(text.prefix(60)) chunk \(chunk)",
          fileID: fileID, filePath: filePath, line: line, column: column
        )
      }
    }
  }

  @Test(arguments: [
    "[1, 2, 3]", "[1,2,3]", "[-1, -2.5e3, 0, 1e-2]", "[12345678, 123456789012, 0.5]",
    "[1,  2]", "[1,\n 2]", "[1, 2 ]", "[ 1 , 2,3 , 4]", "[1 ,2]", "[1,\t2]",
    "[[1, 2], [3, 4]]", "[[1,2],[3,4]]", "[1, true, 2, null, 3, false]", "[1, [2, 3], 4]",
    #"{"a":1, "b":2}"#, #"{"a":[1, 2, 3], "b":[4,5]}"#, #"[{"a":1}, {"a":2}]"#,
    "[1, 2, 3", "[1, 2,", "[1, 2, ", "[1, -", "[1,", "1", "[1]", "[-0, 0.0, -0.0e0]",
  ])
  func `Fused separators produce the byte-fed call sequence`(text: String) {
    Self.expectAgreement(text)
  }

  @Test(arguments: [
    "[1, x]", "[1,x]", "[1, -]", "[1, 2x]", "[1, 2 x]", "[1,]", "[1, ]", "[1, 01]", "[1, 1.]",
    "[1, 1e]", "[1, +2]", "[1, .5]", "[1, 2]]", "[1, 2}", "[1, 2, ]", "[1, ,2]", "[1,, 2]",
    #"{"a":1, 2}"#, #"{"a":1,2}"#, #"{"a":1, "b"}"#, "1, 2", "1,2", "[1, 2] 3", "[1, 2],",
    "[1, -2-]", "[1, 2e5e]", "[1, 12345678901234567890123]", "[1, 2\u{0}]",
  ])
  func `Rejected documents report the byte-fed error at the same byte`(text: String) {
    Self.expectAgreement(text)
  }

  @Test(arguments: [1, 2, 3, 4, 5, 9, 10])
  func `A sink refusal stops the fusion at the refused number`(refusing: Int) {
    Self.expectAgreement("[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]", refusing: refusing)
    Self.expectAgreement("[1,2,3,4,5,6,7,8,9,10]", refusing: refusing)
    Self.expectAgreement("[[1, 2], [3, 4], [5, 6], [7, 8], [9, 10]]", refusing: refusing)
  }

  @Test
  func `Long arrays agree whether or not the block walk is signalled`() {
    let flat = "[" + (0..<200).map { "\($0 * 7).\($0 % 13)" }.joined(separator: ", ") + "]"
    Self.expectAgreement(flat)
    let minified = "[" + (0..<200).map { "-\($0)" }.joined(separator: ",") + "]"
    Self.expectAgreement(minified)
    let pairs = "[" + (0..<100).map { "[\($0).5,\($0 + 1).25]" }.joined(separator: ",") + "]"
    Self.expectAgreement(pairs)
    let indented = "[\n" + (0..<200).map { "    \($0)" }.joined(separator: ",\n") + "\n]"
    Self.expectAgreement(indented)
    let mixed = "[" + (0..<100).map { "\($0), \"s\($0)\"" }.joined(separator: ", ") + "]"
    // String values are cut by the chunking, so this one compares only the chunkings that keep
    // each string whole against the bulk parse.
    let bytes = Array(mixed.utf8)
    let expected = Self.run(bytes, chunk: .max)
    for chunk in [4096, 100_000] {
      expectNoDifference(Self.run(bytes, chunk: chunk), expected, "mixed chunk \(chunk)")
    }
  }
}
