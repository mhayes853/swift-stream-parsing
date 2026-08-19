import CustomDump
import Testing

import StreamParsingCore

// Depth is tracked in a 64-bit container bitmask — 1 for an object, 0 for an array — so the cap
// is not a policy number but the width of a register. That makes the boundary worth pinning from
// both sides and in both container kinds, and makes a mixed nest worth pinning at all: an object
// closed by `]` is only caught if the bit for that level survived everything under it.
//
// `DepthBenchmarks` measures the same spine; `ErrorOffsetTests` pins where the failure is
// reported. This pins what is accepted.
@Suite
struct `Depth limit tests` {
  private static func parse(_ json: String, chunk: Int = .max) throws {
    var parser = JSONParser()
    var sink = CountingConformanceSink()
    let bytes = Array(json.utf8)
    try bytes.withUnsafeBufferPointer { input in
      var i = 0
      while i < input.count {
        let count = Swift.min(chunk, input.count - i)
        try parser.parse(UnsafeBufferPointer(start: input.baseAddress! + i, count: count), into: &sink)
        i += count
      }
    }
    try parser.finish(into: &sink)
  }

  private static func failure(_ json: String, chunk: Int = .max) -> JSONParsingError? {
    do {
      try Self.parse(json, chunk: chunk)
      return nil
    } catch let error as JSONParsingError {
      return error
    } catch {
      return nil
    }
  }

  private static func objects(_ depth: Int) -> String {
    String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
  }

  private static func arrays(_ depth: Int) -> String {
    String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
  }

  @Test(arguments: [1, 2, 32, 63, 64])
  func `Nesting up to the cap is accepted`(depth: Int) throws {
    try Self.parse(Self.objects(depth))
    try Self.parse(Self.arrays(depth))
  }

  @Test(arguments: [65, 66, 128])
  func `Nesting past the cap is rejected`(depth: Int) {
    expectNoDifference(Self.failure(Self.objects(depth))?.reason, .depthExceeded)
    expectNoDifference(Self.failure(Self.arrays(depth))?.reason, .depthExceeded)
  }

  // The cap is a property of the document, not of how it arrived, so a byte fed nest has to fail
  // at the same depth a bulk one does.
  @Test(arguments: [1, 3, .max])
  func `The cap does not depend on chunking`(chunk: Int) throws {
    try Self.parse(Self.objects(64), chunk: chunk)
    expectNoDifference(Self.failure(Self.objects(65), chunk: chunk)?.reason, .depthExceeded)
    try Self.parse(Self.arrays(64), chunk: chunk)
    expectNoDifference(Self.failure(Self.arrays(65), chunk: chunk)?.reason, .depthExceeded)
  }

  // Alternating kinds put a different bit at every level, so a mask that shifted wrong would
  // still accept a uniform nest and fail here.
  @Test
  func `Alternating containers nest to the cap`() throws {
    var json = ""
    var close = ""
    for level in 0..<64 {
      if level.isMultiple(of: 2) {
        json += #"{"a":"#
        close = "}" + close
      } else {
        json += "["
        close = "]" + close
      }
    }
    try Self.parse(json + "1" + close)
  }

  // The closing byte is checked against the bit for the level being closed, so a nest that is
  // shallow enough to be legal still has to be closed by the right kind.
  @Test
  func `A container closed by the wrong kind is rejected at every depth`() {
    expectNoDifference(Self.failure(#"{"a":[1}"#)?.reason, .unexpectedToken)
    expectNoDifference(Self.failure(#"[{"a":1]"#)?.reason, .unexpectedToken)

    let deep = String(repeating: #"{"a":"#, count: 63)
    expectNoDifference(Self.failure(deep + "[1}" + String(repeating: "}", count: 63))?.reason, .unexpectedToken)
  }
}
