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

final class AsyncPartialsSubscriber: Sendable {}

actor AsyncPartialsSubscription {
  private var subscriber: AsyncPartialsSubscriber?

  func claim(_ subscriber: AsyncPartialsSubscriber) -> Bool {
    if let currentSubscriber = self.subscriber {
      return currentSubscriber === subscriber
    } else {
      self.subscriber = subscriber
      return true
    }
  }
}

/// A single-subscriber `AsyncSequence` that emits a partial after each input element and one
/// finalized value when the input ends.
///
/// The first iterator to request an element owns the sequence. A different iterator throws
/// ``StreamParsingError/multipleSubscribers`` when it requests an element. Copies of the owning
/// iterator share its position and remain part of the same subscription.
public struct AsyncPartialsSequence<
  Element: StreamParseableRoot,
  Base: AsyncSequence,
  Seq: Sequence<UInt8>
>: AsyncSequence {
  let base: Base
  let format: JSONStreamFormat
  let initialValue: Element
  let bytes: @Sendable (Base.Element) -> Seq
  private let subscription = AsyncPartialsSubscription()

  // AsyncIteratorProtocol requires a copyable conforming type. The box ensures iterator copies
  // share both the underlying iterator position and the uniquely owned parser stream.
  final class Box {
    let base: Base
    let subscriber = AsyncPartialsSubscriber()
    var baseIterator: Base.AsyncIterator?
    var stream: PartialsStream<Element>
    var hasClaimedSubscription: Bool?
    var hasEmittedFinal = false

    init(base: Base, stream: consuming PartialsStream<Element>) {
      self.base = base
      self.stream = stream
    }

    func nextBaseElement() async throws -> Base.Element? {
      if self.baseIterator == nil {
        self.baseIterator = self.base.makeAsyncIterator()
      }
      return try await self.baseIterator?.next()
    }
  }

  public struct AsyncIterator: AsyncIteratorProtocol {
    let box: Box
    let subscription: AsyncPartialsSubscription
    let bytes: @Sendable (Base.Element) -> Seq

    public mutating func next() async throws -> Element? {
      if self.box.hasClaimedSubscription == nil {
        self.box.hasClaimedSubscription = await self.subscription.claim(self.box.subscriber)
      }
      guard self.box.hasClaimedSubscription == true else {
        throw StreamParsingError.multipleSubscribers
      }
      guard !self.box.hasEmittedFinal else { return nil }
      guard let nextValue = try await self.box.nextBaseElement() else {
        self.box.hasEmittedFinal = true
        return try self.box.stream.finish()
      }
      try self.box.stream.next(self.bytes(nextValue))
      return self.box.stream.current
    }
  }

  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(
      box: Box(
        base: self.base,
        stream: PartialsStream(initialValue: self.initialValue, from: self.format)
      ),
      subscription: self.subscription,
      bytes: self.bytes
    )
  }
}

extension AsyncPartialsSequence: Sendable
where Element: Sendable, Base: Sendable, Seq: Sendable {}
#endif
