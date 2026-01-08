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
}
