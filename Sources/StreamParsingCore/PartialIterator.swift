/// An observed value and whether EOF validation has succeeded.
/// Completion is emitted separately even when the value has not changed.
public struct PartialUpdate<Value> {
  public var value: Value
  public var isComplete: Bool

  public init(value: Value, isComplete: Bool) {
    self.value = value
    self.isComplete = isComplete
  }
}

extension PartialUpdate: Equatable where Value: Equatable {}
extension PartialUpdate: Sendable where Value: Sendable {}

/// A single-pass, noncopyable throwing iterator over synchronous input.
/// Consumes one input element per request, then emits one completed update at EOF.
/// After completion or any error, `next()` returns nil without consuming more input.
/// Empty chunks still produce an update. No initial update is emitted.
public struct PartialIterator<
  Parseable: StreamParseable,
  Base: IteratorProtocol,
  Bytes: Sequence<UInt8>
>: ~Copyable {
  @usableFromInline
  var base: Base
  @usableFromInline
  var stream: PartialsStream<Parseable>
  @usableFromInline
  let bytes: (Base.Element) -> Bytes
  @usableFromInline
  var terminated = false

  init(
    base: Base,
    initialValue: Parseable.Partial,
    format: JSONStreamFormat,
    bytes: @escaping (Base.Element) -> Bytes
  ) {
    self.base = base
    self.stream = PartialsStream(initialValue: initialValue, from: format)
    self.bytes = bytes
  }

  public mutating func next() throws -> PartialUpdate<Parseable.Partial>? {
    guard !self.terminated else { return nil }
    do {
      if let element = self.base.next() {
        try self.stream.next(self.bytes(element))
        return PartialUpdate(value: self.stream.current, isComplete: false)
      }
      self.terminated = true
      return PartialUpdate(value: try self.stream.finish(), isComplete: true)
    } catch {
      self.terminated = true
      throw error
    }
  }
}

extension Sequence where Element == UInt8 {
  /// Lazily parses input; call the throwing `next()` until it returns nil.
  ///
  /// ```swift
  /// var updates = bytes.partialIterator(of: BlogPost.self, from: .json())
  /// while let update = try updates.next() {
  ///   print(update.value, update.isComplete)
  /// }
  /// ```
  public func partialIterator<Parseable: StreamParseable>(
    of type: Parseable.Type,
    from format: JSONStreamFormat
  ) -> PartialIterator<Parseable, Iterator, CollectionOfOne<UInt8>> {
    PartialIterator(
      base: self.makeIterator(),
      initialValue: Parseable.Partial.streamInitialValue(),
      format: format,
      bytes: { CollectionOfOne($0) }
    )
  }

  /// Lazily parses input from a seeded partial; call the throwing `next()` until it returns nil.
  public func partialIterator<Value: StreamParseable>(
    initialValue: Value,
    from format: JSONStreamFormat
  ) -> PartialIterator<Value, Iterator, CollectionOfOne<UInt8>>
  where Value.Partial == Value {
    PartialIterator(
      base: self.makeIterator(),
      initialValue: initialValue,
      format: format,
      bytes: { CollectionOfOne($0) }
    )
  }

  /// Lends a view after each input element and once after successful EOF validation.
  /// The Boolean marks that final emission. Lifetime views cannot escape the callback; default
  /// views are unsafe and must not be retained or used across parser mutation.
  /// A parser or callback error stops consumption immediately and is rethrown.
#if !LifetimeView
  @unsafe
#endif
  public func withPartialViews<Parseable: StreamParseable>(
    of type: Parseable.Type,
    from format: JSONStreamFormat,
    _ body: (borrowing Parseable.Partial.View, Bool) throws -> Void
  ) throws {
    var stream = PartialsStream<Parseable>(from: format)
    for element in self {
      try stream.next(element)
      try stream.withView { try body($0, false) }
    }
    try stream.finishWithView { try body($0, true) }
  }

  /// Lends a view of a seeded partial after each input element and once after successful EOF
  /// validation. See ``withPartialViews(of:from:_:)``.
#if !LifetimeView
  @unsafe
#endif
  public func withPartialViews<Value: StreamParseable>(
    initialValue: Value,
    from format: JSONStreamFormat,
    _ body: (borrowing Value.Partial.View, Bool) throws -> Void
  ) throws where Value.Partial == Value {
    var stream = PartialsStream(initialValue: initialValue, from: format)
    for element in self {
      try stream.next(element)
      try stream.withView { try body($0, false) }
    }
    try stream.finishWithView { try body($0, true) }
  }
}

extension Sequence where Element: Sequence<UInt8> {
  /// Lazily parses chunks of input; call the throwing `next()` until it returns nil.
  public func partialIterator<Parseable: StreamParseable>(
    of type: Parseable.Type,
    from format: JSONStreamFormat
  ) -> PartialIterator<Parseable, Iterator, Element> {
    PartialIterator(
      base: self.makeIterator(),
      initialValue: Parseable.Partial.streamInitialValue(),
      format: format,
      bytes: { $0 }
    )
  }

  /// Lazily parses chunks of input from a seeded partial; call the throwing `next()` until it
  /// returns nil.
  public func partialIterator<Value: StreamParseable>(
    initialValue: Value,
    from format: JSONStreamFormat
  ) -> PartialIterator<Value, Iterator, Element> where Value.Partial == Value {
    PartialIterator(
      base: self.makeIterator(),
      initialValue: initialValue,
      format: format,
      bytes: { $0 }
    )
  }

  /// Lends a view after each input element and once after successful EOF validation.
  /// The Boolean marks that final emission. Lifetime views cannot escape the callback; default
  /// views are unsafe and must not be retained or used across parser mutation.
  /// A parser or callback error stops consumption immediately and is rethrown.
#if !LifetimeView
  @unsafe
#endif
  public func withPartialViews<Parseable: StreamParseable>(
    of type: Parseable.Type,
    from format: JSONStreamFormat,
    _ body: (borrowing Parseable.Partial.View, Bool) throws -> Void
  ) throws {
    var stream = PartialsStream<Parseable>(from: format)
    for element in self {
      try stream.next(element)
      try stream.withView { try body($0, false) }
    }
    try stream.finishWithView { try body($0, true) }
  }

  /// Lends a view of a seeded partial after each input element and once after successful EOF
  /// validation. See ``withPartialViews(of:from:_:)``.
#if !LifetimeView
  @unsafe
#endif
  public func withPartialViews<Value: StreamParseable>(
    initialValue: Value,
    from format: JSONStreamFormat,
    _ body: (borrowing Value.Partial.View, Bool) throws -> Void
  ) throws where Value.Partial == Value {
    var stream = PartialsStream(initialValue: initialValue, from: format)
    for element in self {
      try stream.next(element)
      try stream.withView { try body($0, false) }
    }
    try stream.finishWithView { try body($0, true) }
  }
}
