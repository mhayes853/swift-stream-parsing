import StreamParsing
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
    var stream = PartialsStream(initialValue: [Int](), from: .json())
    for byte in "[1,2".utf8 {
      try stream.next(byte)
    }
    #expect(stream.current == [1])
    #expect(throws: JSONParsingError.self) {
      _ = try stream.finish()
    }
  }

  // The sink holds pointers into the value, and the value lives in its own allocation so those
  // survive the stream being moved. Nesting is where a stale pointer would show up.
  @Test
  func `Deeply Nested Values Update Across Bytes`() throws {
    var stream = PartialsStream(initialValue: [[Int]](), from: .json())
    for byte in "[[1],[2,3]]".utf8 {
      try stream.next(byte)
    }
    #expect(try stream.finish() == [[1], [2, 3]])
  }
}
