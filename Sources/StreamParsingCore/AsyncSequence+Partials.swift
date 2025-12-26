extension AsyncSequence where Element == UInt8 {
  public func partials<Parseable, Parser>(
    of parseable: Parseable.Type,
    from parser: Parser
  ) -> AsyncPartialsSequence<Parseable, Parser> {
    AsyncPartialsSequence(parser: parser)
  }
}

extension AsyncSequence where Element: Sequence<UInt8> {
  public func partials<Parseable, Parser>(
    of parseable: Parseable.Type,
    from parser: Parser
  ) -> AsyncPartialsSequence<Parseable, Parser> {
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
