import CustomDump
import StreamParsingCore
import Testing

@Suite
struct `String run fusion tests` {
  private static func withBase<R>(
    _ bytes: [UInt8],
    _ body: (UnsafeRawPointer) -> R
  ) -> R {
    bytes.withUnsafeBytes { body($0.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!) }
  }

  private static func scan(_ bytes: [UInt8], from: Int = 0) -> StreamStringRun {
    Self.withBase(bytes) {
      streamStringRun(base: $0, from: from, to: bytes.count)
    }
  }

  private static func parse(_ bytes: [UInt8], splitAt: Int) throws {
    var parser = JSONParser()
    var sink = CountingConformanceSink()
    try bytes.withUnsafeBufferPointer { buffer in
      let first = UnsafeBufferPointer(start: buffer.baseAddress, count: splitAt)
      let second = UnsafeBufferPointer(
        start: buffer.baseAddress! + splitAt,
        count: buffer.count &- splitAt
      )
      if !first.isEmpty { try parser.parse(first, into: &sink) }
      if !second.isEmpty { try parser.parse(second, into: &sink) }
    }
    try parser.finish(into: &sink)
  }

  @Test
  func `ASCII Runs Never Require UTF8 Validation`() {
    for length in 0...64 {
      let bytes = [UInt8](repeating: 0x61, count: length)
      for from in 0...length {
        expectNoDifference(
          Self.scan(bytes, from: from),
          StreamStringRun(end: length, containsNonASCII: false),
          "length \(length) from \(from)"
        )
      }
    }
  }

  @Test
  func `NonASCII Before The Run End Requires UTF8 Validation`() {
    for terminator in 1...64 {
      for nonASCII in 0..<terminator {
        var bytes = [UInt8](repeating: 0x61, count: 65)
        bytes[nonASCII] = 0xC3
        bytes[terminator] = 0x22
        expectNoDifference(
          Self.scan(bytes),
          StreamStringRun(end: terminator, containsNonASCII: true),
          "non-ASCII at \(nonASCII), terminator at \(terminator)"
        )
      }
    }
  }

  @Test
  func `NonASCII After The Run End Does Not Require UTF8 Validation`() {
    for terminator in 0..<64 {
      for nonASCII in (terminator &+ 1)...64 {
        var bytes = [UInt8](repeating: 0x61, count: 65)
        bytes[terminator] = 0x22
        bytes[nonASCII] = 0xC3
        expectNoDifference(
          Self.scan(bytes),
          StreamStringRun(end: terminator, containsNonASCII: false),
          "terminator at \(terminator), non-ASCII at \(nonASCII)"
        )
      }
    }
  }

  @Test
  func `Valid UTF8 Keys Pass At Every Split`() {
    let bytes = Array(#"{"café":null}"#.utf8)
    for split in 0...bytes.count {
      #expect(throws: Never.self, "split at \(split)") {
        try Self.parse(bytes, splitAt: split)
      }
    }
  }

  @Test
  func `Invalid UTF8 Keys Fail At Every Split`() {
    let bytes: [UInt8] = [
      0x7B, 0x22, 0x62, 0x61, 0x64, 0x80, 0x22, 0x3A, 0x6E, 0x75, 0x6C, 0x6C, 0x7D
    ]
    for split in 0...bytes.count {
      #expect(throws: JSONParsingError.self, "split at \(split)") {
        try Self.parse(bytes, splitAt: split)
      }
    }
  }
}
