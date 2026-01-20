import StreamParsing
import Testing

@Suite
struct `PartialsStream Tests` {
  @Test
  func `Throws When Finish Called Twice`() throws {
    let parser = MockParser<Int>(actions: [:])
    var stream = PartialsStream(initialValue: 0, from: parser)

    _ = try stream.finish()
    #expect(throws: StreamParsingError.parserFinished) {
      _ = try stream.finish()
    }
  }

  @Test
  func `Rejects Next After Parser Throws`() throws {
    let parser = MockParser<Int>(
      actions: [:],
      throwOnByte: .mockParserThrows
    )
    var stream = PartialsStream(initialValue: 0, from: parser)

    #expect(throws: MockParserError.self) {
      _ = try stream.next(.mockParserThrows)
    }

    #expect(throws: StreamParsingError.parserThrows) {
      _ = try stream.next(0x7F)
    }
  }

  @Test
  func `Finish Throws After Parser Throws`() throws {
    let parser = MockParser<Int>(
      actions: [:],
      throwOnByte: .mockParserThrows
    )
    var stream = PartialsStream(initialValue: 0, from: parser)

    #expect(throws: MockParserError.self) {
      _ = try stream.next(.mockParserThrows)
    }

    #expect(throws: StreamParsingError.parserThrows) {
      _ = try stream.finish()
    }
  }
}
