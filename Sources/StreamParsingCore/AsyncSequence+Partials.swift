extension AsyncSequence where Element == UInt8 {
  public func partials<Value, Parser>(
    initialValue: Value = .initialParseableValue(),
    from parser: Parser
  ) -> AsyncPartialsSequence<Value, Parser, Self, CollectionOfOne<UInt8>> {
    AsyncPartialsSequence(
      base: self,
      parser: parser,
      initialValue: initialValue,
      bytesPath: \.collection
    )
  }
}

extension AsyncSequence where Element: Sequence<UInt8> & Sendable {
  public func partials<Value, Parser>(
    initialValue: Value = .initialParseableValue(),
    from parser: Parser
  ) -> AsyncPartialsSequence<Value, Parser, Self, Element> {
    AsyncPartialsSequence(
      base: self,
      parser: parser,
      initialValue: initialValue,
      bytesPath: \.self
    )
  }
}

public struct AsyncPartialsSequence<
  Element: StreamParseableValue,
  Parser: StreamParser<Element>,
  Base: AsyncSequence,
  Seq: Sequence<UInt8>
>: AsyncSequence {
  let base: Base
  let parser: Parser
  let initialValue: Element
  let bytesPath: KeyPath<Base.Element, Seq> & Sendable

  public struct AsyncIterator: AsyncIteratorProtocol {
    var baseIterator: Base.AsyncIterator
    var stream: PartialsStream<Element, Parser>
    let bytesPath: KeyPath<Base.Element, Seq> & Sendable

    public mutating func next() async throws -> Element? {
      guard let nextValue = try await self.baseIterator.next() else {
        try self.stream.finish()
        return nil
      }
      return try self.stream.next(nextValue[keyPath: self.bytesPath])
    }
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      baseIterator: self.base.makeAsyncIterator(),
      stream: PartialsStream(
        initialValue: self.initialValue,
        from: self.parser
      ),
      bytesPath: self.bytesPath
    )
  }
}

extension AsyncPartialsSequence: Sendable
where Element: Sendable, Parser: Sendable, Base: Sendable, Seq: Sendable {}

extension AsyncPartialsSequence.AsyncIterator: Sendable
where Element: Sendable, Parser: Sendable, Base.AsyncIterator: Sendable, Seq: Sendable {}

// MARK: - Helpers

extension UInt8 {
  fileprivate var collection: CollectionOfOne<Self> {
    CollectionOfOne(self)
  }
}
