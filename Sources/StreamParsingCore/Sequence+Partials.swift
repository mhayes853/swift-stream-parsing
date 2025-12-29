// MARK: - PartialsSequence

extension Sequence where Element == UInt8 {
  public func partials<Parseable, Parser>(
    of parseable: Parseable.Type,
    from parser: Parser
  ) -> PartialsSequence<Parseable, Parser, Self>
  where Parseable.Partial.Action == Parser.Action {
    PartialsSequence(base: self, parser: parser) { .single($0) }
  }
}

extension Sequence where Element: Sequence<UInt8> {
  public func partials<Parseable, Parser>(
    of parseable: Parseable.Type,
    from parser: Parser
  ) -> PartialsSequence<Parseable, Parser, Self>
  where Parseable.Partial.Action == Parser.Action {
    PartialsSequence(base: self, parser: parser) { .sequence($0) }
  }
}

public struct PartialsSequence<
  Parseable: StreamParseable,
  Parser: StreamParser,
  Base: Sequence
>: Sequence where Parseable.Partial.Action == Parser.Action {
  public typealias Element = Parseable.Partial

  let base: Base
  let parser: Parser
  fileprivate let byteInput: (Base.Element) -> ByteInput

  public struct Iterator: IteratorProtocol {
    var baseIterator: Base.Iterator
    var stream: PartialsStream<Parseable, Parser>
    fileprivate let byteInput: (Base.Element) -> ByteInput
    var error: Error?

    public mutating func next() -> Parseable.Partial? {
      guard error == nil, let element = baseIterator.next() else {
        return nil
      }
      do {
        switch byteInput(element) {
        case .single(let byte):
          return try stream.next(byte)
        case .sequence(let bytes):
          return try stream.next(bytes)
        }
      } catch {
        self.error = error
        return nil
      }
    }
  }

  public func makeIterator() -> Iterator {
    Iterator(
      baseIterator: base.makeIterator(),
      stream: PartialsStream(of: Parseable.self, from: parser),
      byteInput: byteInput,
      error: nil
    )
  }
}
