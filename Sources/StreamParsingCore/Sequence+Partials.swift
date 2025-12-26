extension Sequence where Element: StreamParseable {
  public func partials<Parser>(from parser: Parser) -> PartialsSequence<Element, Parser> {
    PartialsSequence(parser: parser)
  }
}

public struct PartialsSequence<Element: StreamParseable, Parser: StreamParser>: Sequence {
  let parser: Parser

  public struct Iterator: IteratorProtocol {
    public mutating func next() -> Element.Partial? {
      fatalError()
    }
  }

  public func makeIterator() -> Iterator {
    Iterator()
  }
}
