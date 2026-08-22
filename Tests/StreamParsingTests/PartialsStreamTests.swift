import StreamParsing
import CustomDump
import Testing

@Suite
struct `PartialsStream Tests` {
  @Test
  func `Throws When Finish Called Twice`() throws {
    var stream = PartialsStream(initialValue: 0, from: .json())
    try stream.next(UInt8(ascii: "1"))

    _ = try stream.finish()
    #expect(throws: StreamParsingError.parserFinished) {
      _ = try stream.finish()
    }
  }

  @Test(arguments: [UInt8(ascii: " "), UInt8(ascii: "2")])
  func `Rejects A Byte After Finish`(byte: UInt8) throws {
    var stream = PartialsStream(initialValue: 0, from: .json())
    try stream.next(UInt8(ascii: "1"))
    _ = try stream.finish()

    #expect(throws: StreamParsingError.parserFinished) {
      try stream.next(byte)
    }
  }

  @Test(arguments: [[UInt8](), [UInt8(ascii: " ")], [UInt8(ascii: "2")]])
  func `Rejects A Sequence After Finish`(bytes: [UInt8]) throws {
    var stream = PartialsStream(initialValue: 0, from: .json())
    try stream.next(UInt8(ascii: "1"))
    _ = try stream.finish()

    #expect(throws: StreamParsingError.parserFinished) {
      try stream.next(bytes)
    }
  }

  @Test
  func `Rejects Next After Parser Throws`() throws {
    var stream = PartialsStream(initialValue: 0, from: .json())

    #expect(throws: JSONParsingError.self) {
      _ = try stream.next(UInt8(ascii: "@"))
    }

    #expect(throws: StreamParsingError.parserThrows) {
      _ = try stream.next(UInt8(ascii: "1"))
    }
  }

  @Test
  func `Finish Throws After Parser Throws`() throws {
    var stream = PartialsStream(initialValue: 0, from: .json())

    #expect(throws: JSONParsingError.self) {
      _ = try stream.next(UInt8(ascii: "@"))
    }

    #expect(throws: StreamParsingError.parserThrows) {
      _ = try stream.finish()
    }
  }

  // An incomplete document is only an error at the end, which is the whole point of a streaming
  // parser: every prefix is a legitimate state until the caller says there is no more input.
  @Test
  func `Finish Throws On An Incomplete Document`() throws {
    var stream = PartialsStream(initialValue: StreamArray<Int>(), from: .json())
    for byte in "[1,2".utf8 {
      try stream.next(byte)
    }
    // The trailing 2 is still an open token, so it is not part of any state yet.
    expectNoDifference(stream.current, [1])
    #expect(throws: JSONParsingError.self) {
      _ = try stream.finish()
    }
  }

  // The sink holds pointers into the value, and the value lives in its own allocation so those
  // survive the stream being moved. Nesting is where a stale pointer would show up.
  @Test
  func `Deeply Nested Values Update Across Bytes`() throws {
    var stream = PartialsStream(initialValue: StreamArray<StreamArray<Int>>(), from: .json())
    for byte in "[[1],[2,3]]".utf8 {
      try stream.next(byte)
    }
    expectNoDifference(try stream.finish(), [[1], [2, 3]])
  }
}
