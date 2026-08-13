// Embedded Swift has no AsyncSequence in the 6.3 SDK and no use for one regardless: a target
// with no scheduler is not consuming an async byte stream. Gated rather than conditionally
// available, so the rest of the core stays embedded clean on both toolchains.
#if !hasFeature(Embedded)
extension AsyncSequence where Element == UInt8 {
  /// Incrementally parses bytes as a value in an async sequence.
  ///
  /// ```swift
  /// let partials = sequence.partials(of: MyModel.self, from: .json())
  /// for try await partial in partials {
  ///   print(partial)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - type: The value type describing each partial state.
  ///   - format: The format describing the parser to drive from the async bytes.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Parseable: StreamParseable>(
    of type: Parseable.Type,
    from format: JSONStreamFormat
  ) -> AsyncPartialsSequence<Parseable.Partial, Self, CollectionOfOne<UInt8>> {
    self.partials(initialValue: Parseable.Partial.streamInitialValue(), from: format)
  }

  /// Incrementally parses bytes as a value in an async sequence.
  ///
  /// - Parameters:
  ///   - type: The value type describing each partial state.
  ///   - format: The format describing the parser to drive from the async bytes.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Value: StreamParseableRoot>(
    of type: Value.Type,
    from format: JSONStreamFormat
  ) -> AsyncPartialsSequence<Value, Self, CollectionOfOne<UInt8>> {
    self.partials(initialValue: Value.streamInitialValue(), from: format)
  }

  /// Incrementally parses bytes as a value in an async sequence.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to resume parsing from.
  ///   - format: The format describing the parser that consumes the incoming bytes.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Value: StreamParseableRoot>(
    initialValue: Value,
    from format: JSONStreamFormat
  ) -> AsyncPartialsSequence<Value, Self, CollectionOfOne<UInt8>> {
    AsyncPartialsSequence(
      base: self,
      format: format,
      initialValue: initialValue,
      bytes: { CollectionOfOne($0) }
    )
  }
}

extension AsyncSequence where Element: Sequence<UInt8> & Sendable {
  /// Incrementally parses chunks of bytes as a value in an async sequence.
  ///
  /// - Parameters:
  ///   - type: The value type describing each partial state.
  ///   - format: The format describing the parser that processes the collected sequences.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Parseable: StreamParseable>(
    of type: Parseable.Type,
    from format: JSONStreamFormat
  ) -> AsyncPartialsSequence<Parseable.Partial, Self, Element> {
    self.partials(initialValue: Parseable.Partial.streamInitialValue(), from: format)
  }

  /// Incrementally parses chunks of bytes as a value in an async sequence.
  ///
  /// - Parameters:
  ///   - type: The value type represented by each partial.
  ///   - format: The format describing the parser that processes the collected sequences.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Value: StreamParseableRoot>(
    of type: Value.Type,
    from format: JSONStreamFormat
  ) -> AsyncPartialsSequence<Value, Self, Element> {
    self.partials(initialValue: Value.streamInitialValue(), from: format)
  }

  /// Incrementally parses chunks of bytes as a value in an async sequence.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to parse from.
  ///   - format: The format describing the parser that consumes each chunk of bytes.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Value: StreamParseableRoot>(
    initialValue: Value,
    from format: JSONStreamFormat
  ) -> AsyncPartialsSequence<Value, Self, Element> {
    AsyncPartialsSequence(base: self, format: format, initialValue: initialValue, bytes: { $0 })
  }
}

/// An `AsyncSequence` that incrementally parses a byte stream.
public struct AsyncPartialsSequence<
  Element: StreamParseableRoot,
  Base: AsyncSequence,
  Seq: Sequence<UInt8>
>: AsyncSequence {
  let base: Base
  let format: JSONStreamFormat
  let initialValue: Element
  let bytes: @Sendable (Base.Element) -> Seq

  // AsyncIteratorProtocol requires a copyable conforming type, and PartialsStream is not one:
  // it owns a parser buffer and an allocation the sink points into. The box gives the iterator
  // something copyable to hold while the stream itself stays uniquely owned.
  public final class Box {
    var stream: PartialsStream<Element>

    init(stream: consuming PartialsStream<Element>) {
      self.stream = stream
    }
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    var baseIterator: Base.AsyncIterator
    let box: Box
    let bytes: @Sendable (Base.Element) -> Seq

    public mutating func next() async throws -> Element? {
      guard let nextValue = try await self.baseIterator.next() else {
        try self.box.stream.finish()
        return nil
      }
      try self.box.stream.next(self.bytes(nextValue))
      return self.box.stream.current
    }
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      baseIterator: self.base.makeAsyncIterator(),
      box: Box(stream: PartialsStream(initialValue: self.initialValue, from: self.format)),
      bytes: self.bytes
    )
  }
}

extension AsyncPartialsSequence: Sendable
where Element: Sendable, Base: Sendable, Seq: Sendable {}
#endif
