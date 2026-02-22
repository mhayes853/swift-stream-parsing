extension AsyncSequence where Element == UInt8 {
  /// Incrementally parses bytes as a value in an async sequence.
  ///
  /// ```swift
  /// @StreamParseable
  /// struct MyModel {
  ///   // ...
  /// }
  ///
  /// let partials = sequence.partials(of: MyModel.self, from: .json())
  /// for try await partial in partials {
  ///   print(partial)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - type: The value type describing each partial state.
  ///   - parser: The parser to drive from the async bytes.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Parseable: StreamParseable, Parser>(
    of type: Parseable.Type,
    from parser: Parser
  ) -> AsyncPartialsSequence<Parseable.Partial, Parser, Self, CollectionOfOne<UInt8>> {
    self.partials(initialValue: type.Partial.initialParseableValue(), from: parser)
  }

  /// Incrementally parses bytes as a value in an async sequence.
  ///
  /// ```swift
  /// @StreamParseable
  /// struct MyModel {
  ///   // ...
  /// }
  ///
  /// let partials = sequence.partials(of: MyModel.Partial.self, from: .json())
  /// for try await partial in partials {
  ///   print(partial)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - type: The value type describing each partial state.
  ///   - parser: The parser to drive from the async bytes.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Value, Parser>(
    of type: Value.Type,
    from parser: Parser
  ) -> AsyncPartialsSequence<Value, Parser, Self, CollectionOfOne<UInt8>> {
    self.partials(initialValue: type.initialParseableValue(), from: parser)
  }

  /// Incrementally parses bytes as a value in an async sequence.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to resume parsing from.
  ///   - parser: The parser that consumes the incoming bytes.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Value, Parser>(
    initialValue: Value,
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
  /// Incrementally parses bytes as a value in an async sequence.
  ///
  /// ```swift
  /// @StreamParseable
  /// struct MyModel {
  ///   // ...
  /// }
  ///
  /// let partials = sequence.partials(of: MyModel.self, from: .json())
  /// for try await partial in partials {
  ///   print(partial)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - type: The value type describing each partial state.
  ///   - parser: The parser that processes the collected sequences.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Parseable: StreamParseable, Parser>(
    of type: Parseable.Type,
    from parser: Parser
  ) -> AsyncPartialsSequence<Parseable.Partial, Parser, Self, Element> {
    self.partials(initialValue: type.Partial.initialParseableValue(), from: parser)
  }

  /// Incrementally parses a chunk of byte as a value in an async sequence.
  ///
  /// ```swift
  /// @StreamParseable
  /// struct MyModel {
  ///   // ...
  /// }
  ///
  /// let partials = sequence.partials(of: MyModel.Partial.self, from: .json())
  /// for try await partial in partials {
  ///   print(partial)
  /// }
  /// ```
  ///
  /// - Parameters:
  ///   - type: The value type represented by each partial.
  ///   - parser: The parser that processes the collected sequences.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Value, Parser>(
    of type: Value.Type,
    from parser: Parser
  ) -> AsyncPartialsSequence<Value, Parser, Self, Element> {
    self.partials(initialValue: type.initialParseableValue(), from: parser)
  }

  /// Incrementally parses a chunk of byte as a value in an async sequence.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to parse from.
  ///   - parser: The parser that consumes each chunk of bytes.
  /// - Returns: An ``AsyncPartialsSequence``.
  public func partials<Value, Parser>(
    initialValue: Value,
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

/// An `AsyncSequence` that incrementally parses a byte stream.
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
