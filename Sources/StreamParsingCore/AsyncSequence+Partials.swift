extension AsyncSequence where Element: StreamParseable {
  public func partials<Parser>(from parser: Parser) -> AsyncPartialsSequence<Element, Parser> {
    AsyncPartialsSequence(parser: parser)
  }
}

public struct AsyncPartialsSequence<Element: StreamParseable, Parser: StreamParser>: AsyncSequence {
  let parser: Parser

  public struct AsyncIterator: AsyncIteratorProtocol {
    public mutating func next() async throws -> Element.Partial? {
      fatalError()
    }
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator()
  }
}
