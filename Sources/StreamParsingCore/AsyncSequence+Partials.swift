extension AsyncSequence where Element == UInt8 {
  public func partials<Value, Parser>(
    initialValue: Value,
    from parser: Parser
  ) -> AsyncPartialsSequence<Value, Parser, Self, CollectionOfOne<UInt8>> {
    AsyncPartialsSequence(base: self, parser: parser, initialValue: initialValue) {
      CollectionOfOne($0)
    }
  }
}

extension AsyncSequence where Element: Sequence<UInt8> & Sendable {
  public func partials<Value, Parser>(
    initialValue: Value,
    from parser: Parser
  ) -> AsyncPartialsSequence<Value, Parser, Self, Element> {
    AsyncPartialsSequence(base: self, parser: parser, initialValue: initialValue) { $0 }
  }
}

public struct AsyncPartialsSequence<
  Element: StreamParseableReducer,
  Parser: StreamParser,
  Base: AsyncSequence,
  Seq: Sequence<UInt8>
>: AsyncSequence {
  let base: Base
  let parser: Parser
  let initialValue: Element
  let byteInput: @Sendable (Base.Element) -> Seq

  public struct AsyncIterator: AsyncIteratorProtocol {
    var baseIterator: Base.AsyncIterator
    var stream: PartialsStream<Element, Parser>
    let byteInput: @Sendable (Base.Element) -> Seq
    var lastReduceCount: Int

    public mutating func next() async throws -> Element? {
      nil
    }
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      baseIterator: self.base.makeAsyncIterator(),
      stream: PartialsStream(
        initialValue: self.initialValue,
        from: self.parser
      ),
      byteInput: self.byteInput,
      lastReduceCount: 0
    )
  }
}

extension AsyncPartialsSequence: Sendable
where Element: Sendable, Parser: Sendable, Base: Sendable, Seq: Sendable {}

extension AsyncPartialsSequence.AsyncIterator: Sendable
where Element: Sendable, Parser: Sendable, Base.AsyncIterator: Sendable, Seq: Sendable {}
