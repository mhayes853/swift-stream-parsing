// MARK: - AsyncPartialsSequence

extension AsyncSequence where Element == UInt8 {
  public func partials<Value, Parser>(
    initialValue: Value,
    from parser: Parser
  ) -> AsyncPartialsSequence<Value, Parser, Self, CollectionOfOne<UInt8>> {
    AsyncPartialsSequence(base: self, parser: parser, initialValue: initialValue) { .single($0) }
  }
}

extension AsyncSequence where Element: Sequence<UInt8> {
  public func partials<Value, Parser>(
    initialValue: Value,
    from parser: Parser
  ) -> AsyncPartialsSequence<Value, Parser, Self, Element> {
    AsyncPartialsSequence(base: self, parser: parser, initialValue: initialValue) { .sequence($0) }
  }
}

public struct AsyncPartialsSequence<
  Element: StreamActionReducer,
  Parser: StreamParser,
  Base: AsyncSequence,
  Seq: Sequence<UInt8>
>: AsyncSequence where Element.StreamAction == Parser.StreamAction {
  fileprivate enum ByteInput {
    case single(UInt8)
    case sequence(Seq)
  }

  let base: Base
  let parser: Parser
  let initialValue: Element
  fileprivate let byteInput: (Base.Element) -> ByteInput

  public struct AsyncIterator: AsyncIteratorProtocol {
    var baseIterator: Base.AsyncIterator
    var stream: PartialsStream<Element, Parser>
    fileprivate let byteInput: (Base.Element) -> ByteInput

    public mutating func next() async throws -> Element? {
      guard let element = try await self.baseIterator.next() else { return nil }
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
      stream: PartialsStream(initialValue: self.initialValue, from: self.parser),
      byteInput: self.byteInput
    )
  }
}
