// MARK: - AsyncPartialsSequence

extension AsyncSequence where Element == UInt8 {
  public func partials<Parseable, Parser>(
    of parseable: Parseable.Type,
    from parser: Parser
  ) -> AsyncPartialsSequence<Parseable, Parser, Self, CollectionOfOne<UInt8>> {
    AsyncPartialsSequence(base: self, parser: parser) { .single($0) }
  }
}

extension AsyncSequence where Element: Sequence<UInt8> {
  public func partials<Parseable, Parser>(
    of parseable: Parseable.Type,
    from parser: Parser
  ) -> AsyncPartialsSequence<Parseable, Parser, Self, Element> {
    AsyncPartialsSequence(base: self, parser: parser) { .sequence($0) }
  }
}

public struct AsyncPartialsSequence<
  Parseable: StreamParseable,
  Parser: StreamParser,
  Base: AsyncSequence,
  Seq: Sequence<UInt8>
>: AsyncSequence where Parseable.Partial.StreamAction == Parser.StreamAction {
  public typealias Element = Parseable.Partial

  fileprivate enum ByteInput {
    case single(UInt8)
    case sequence(Seq)
  }

  let base: Base
  let parser: Parser
  fileprivate let byteInput: (Base.Element) -> ByteInput

  public struct AsyncIterator: AsyncIteratorProtocol {
    var baseIterator: Base.AsyncIterator
    var stream: PartialsStream<Parseable, Parser>
    fileprivate let byteInput: (Base.Element) -> ByteInput

    public mutating func next() async throws -> Parseable.Partial? {
      guard let element = try await self.baseIterator.next() else {
        return nil
      }
      switch self.byteInput(element) {
      case .single(let byte):
        return try self.stream.next(byte)
      case .sequence(let bytes):
        return try self.stream.next(bytes)
      }
    }
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      baseIterator: self.base.makeAsyncIterator(),
      stream: PartialsStream(of: Parseable.self, from: self.parser),
      byteInput: self.byteInput
    )
  }
}
