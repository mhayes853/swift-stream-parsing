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
  Value: StreamParseableRoot,
  Base: IteratorProtocol,
  Bytes: Sequence<UInt8>
>: ~Copyable {
  @usableFromInline
  var base: Base
  @usableFromInline
  var stream: PartialsStream<Value>
  @usableFromInline
  let bytes: (Base.Element) -> Bytes
  @usableFromInline
  var terminated = false

  init(
    base: Base,
    initialValue: Value,
    format: JSONStreamFormat,
    bytes: @escaping (Base.Element) -> Bytes
  ) {
    self.base = base
    self.stream = PartialsStream(initialValue: initialValue, from: format)
    self.bytes = bytes
  }

  public mutating func next() throws -> PartialUpdate<Value>? {
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
  public func partialIterator<Value: StreamParseable>(
    of type: Value.Type,
    from format: JSONStreamFormat
  ) -> PartialIterator<Value.Partial, Iterator, CollectionOfOne<UInt8>> {
    PartialIterator(
      base: self.makeIterator(),
      initialValue: Value.Partial.streamInitialValue(),
      format: format,
      bytes: { CollectionOfOne($0) }
    )
  }

  /// Lends a view after each input element and once after successful EOF validation.
  /// The Boolean marks that final emission. Views cannot escape the callback.
  /// A parser or callback error stops consumption immediately and is rethrown.
  public func withPartialViews<Value: StreamParseable>(
    of type: Value.Type,
    from format: JSONStreamFormat,
    _ body: (borrowing Value.Partial.View, Bool) throws -> Void
  ) throws {
    var stream = PartialsStream(initialValue: Value.Partial.streamInitialValue(), from: format)
    for element in self {
      try stream.next(element)
      try stream.withView { try body($0, false) }
    }
    try stream.finishWithView { try body($0, true) }
  }

  /// Lazily parses input; call the throwing `next()` until it returns nil.
  @_disfavoredOverload
  public func partialIterator<Value: StreamParseableRoot>(
    of type: Value.Type,
    from format: JSONStreamFormat
  ) -> PartialIterator<Value, Iterator, CollectionOfOne<UInt8>> {
    PartialIterator(
      base: self.makeIterator(),
      initialValue: Value.streamInitialValue(),
      format: format,
      bytes: { CollectionOfOne($0) }
    )
  }

  /// Lends a view after each input element and once after successful EOF validation.
  /// The Boolean marks that final emission. Views cannot escape the callback.
  /// A parser or callback error stops consumption immediately and is rethrown.
  @_disfavoredOverload
  public func withPartialViews<Value: StreamParseableRoot>(
    of type: Value.Type,
    from format: JSONStreamFormat,
    _ body: (borrowing Value.View, Bool) throws -> Void
  ) throws {
    var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: format)
    for element in self {
      try stream.next(element)
      try stream.withView { try body($0, false) }
    }
    try stream.finishWithView { try body($0, true) }
  }

  /// Lazily parses input; call the throwing `next()` until it returns nil.
  public func partialIterator<Value: StreamParseableRoot>(
    initialValue: Value,
    from format: JSONStreamFormat
  ) -> PartialIterator<Value, Iterator, CollectionOfOne<UInt8>> {
    PartialIterator(
      base: self.makeIterator(),
      initialValue: initialValue,
      format: format,
      bytes: { CollectionOfOne($0) }
    )
  }

  /// Lends a view after each input element and once after successful EOF validation.
  /// The Boolean marks that final emission. Views cannot escape the callback.
  /// A parser or callback error stops consumption immediately and is rethrown.
  public func withPartialViews<Value: StreamParseableRoot>(
    initialValue: Value,
    from format: JSONStreamFormat,
    _ body: (borrowing Value.View, Bool) throws -> Void
  ) throws {
    var stream = PartialsStream(initialValue: initialValue, from: format)
    for element in self {
      try stream.next(element)
      try stream.withView { try body($0, false) }
    }
    try stream.finishWithView { try body($0, true) }
  }

}

extension Sequence where Element: Sequence<UInt8> {
  /// Lazily parses input; call the throwing `next()` until it returns nil.
  public func partialIterator<Value: StreamParseable>(
    of type: Value.Type,
    from format: JSONStreamFormat
  ) -> PartialIterator<Value.Partial, Iterator, Element> {
    PartialIterator(
      base: self.makeIterator(),
      initialValue: Value.Partial.streamInitialValue(),
      format: format,
      bytes: { $0 }
    )
  }

  /// Lends a view after each input element and once after successful EOF validation.
  /// The Boolean marks that final emission. Views cannot escape the callback.
  /// A parser or callback error stops consumption immediately and is rethrown.
  public func withPartialViews<Value: StreamParseable>(
    of type: Value.Type,
    from format: JSONStreamFormat,
    _ body: (borrowing Value.Partial.View, Bool) throws -> Void
  ) throws {
    var stream = PartialsStream(initialValue: Value.Partial.streamInitialValue(), from: format)
    for element in self {
      try stream.next(element)
      try stream.withView { try body($0, false) }
    }
    try stream.finishWithView { try body($0, true) }
  }

  /// Lazily parses input; call the throwing `next()` until it returns nil.
  @_disfavoredOverload
  public func partialIterator<Value: StreamParseableRoot>(
    of type: Value.Type,
    from format: JSONStreamFormat
  ) -> PartialIterator<Value, Iterator, Element> {
    PartialIterator(
      base: self.makeIterator(),
      initialValue: Value.streamInitialValue(),
      format: format,
      bytes: { $0 }
    )
  }

  /// Lends a view after each input element and once after successful EOF validation.
  /// The Boolean marks that final emission. Views cannot escape the callback.
  /// A parser or callback error stops consumption immediately and is rethrown.
  @_disfavoredOverload
  public func withPartialViews<Value: StreamParseableRoot>(
    of type: Value.Type,
    from format: JSONStreamFormat,
    _ body: (borrowing Value.View, Bool) throws -> Void
  ) throws {
    var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: format)
    for element in self {
      try stream.next(element)
      try stream.withView { try body($0, false) }
    }
    try stream.finishWithView { try body($0, true) }
  }

  /// Lazily parses input; call the throwing `next()` until it returns nil.
  public func partialIterator<Value: StreamParseableRoot>(
    initialValue: Value,
    from format: JSONStreamFormat
  ) -> PartialIterator<Value, Iterator, Element> {
    PartialIterator(
      base: self.makeIterator(),
      initialValue: initialValue,
      format: format,
      bytes: { $0 }
    )
  }

  /// Lends a view after each input element and once after successful EOF validation.
  /// The Boolean marks that final emission. Views cannot escape the callback.
  /// A parser or callback error stops consumption immediately and is rethrown.
  public func withPartialViews<Value: StreamParseableRoot>(
    initialValue: Value,
    from format: JSONStreamFormat,
    _ body: (borrowing Value.View, Bool) throws -> Void
  ) throws {
    var stream = PartialsStream(initialValue: initialValue, from: format)
    for element in self {
      try stream.next(element)
      try stream.withView { try body($0, false) }
    }
    try stream.finishWithView { try body($0, true) }
  }

}
