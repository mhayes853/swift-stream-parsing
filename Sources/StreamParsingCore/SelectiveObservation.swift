/// A throwing, single-pass source of owned partial updates.
public protocol PartialUpdateIteratorProtocol: ~Copyable {
  associatedtype Value
  mutating func next() throws -> PartialUpdate<Value>?
}

extension PartialIterator: PartialUpdateIteratorProtocol {}

extension PartialUpdateIteratorProtocol where Self: ~Copyable {
  /// Suppresses equal consecutive values, always preserving the completed update.
  /// Equality must include any field-state information the consumer needs to observe.
  @inlinable
  public consuming func removeDuplicateUpdates(
    by equivalent: @escaping (Value, Value) -> Bool
  ) -> DistinctPartialIterator<Self> {
    DistinctPartialIterator(base: self, equivalent: equivalent)
  }

  @inlinable
  public consuming func removeDuplicateUpdates() -> DistinctPartialIterator<Self>
  where Value: Equatable {
    self.removeDuplicateUpdates(by: ==)
  }
}

/// Retains only the last emitted update for comparison. Errors terminate iteration.
public struct DistinctPartialIterator<Base: PartialUpdateIteratorProtocol & ~Copyable>:
  ~Copyable, PartialUpdateIteratorProtocol
{
  @usableFromInline
  var base: Base
  @usableFromInline
  let equivalent: (Base.Value, Base.Value) -> Bool
  @usableFromInline
  var previous: PartialUpdate<Base.Value>?
  @usableFromInline
  var terminated = false

  @inlinable
  init(base: consuming Base, equivalent: @escaping (Base.Value, Base.Value) -> Bool) {
    self.base = base
    self.equivalent = equivalent
  }

  @inlinable
  public mutating func next() throws -> PartialUpdate<Base.Value>? {
    guard !self.terminated else { return nil }
    do {
      while let update = try self.base.next() {
        if !update.isComplete, let previous = self.previous,
          self.equivalent(previous.value, update.value)
        {
          continue
        }
        self.previous = update
        return update
      }
      self.terminated = true
      return nil
    } catch {
      self.terminated = true
      throw error
    }
  }
}

extension PartialIterator {
  /// Selects an owned value through a borrowed view before taking a whole-root snapshot.
  /// The closure may copy a field or compute a value; its borrowed view cannot escape.
  /// Projection preserves the selected representation, including optional values. It does
  /// not infer field presence, JSON null, or token completion unavailable in that representation.
  @inlinable
#if !LifetimeView
  @unsafe
#endif
  public consuming func project<Output>(
    _ transform: @escaping (borrowing Value.View) throws -> Output
  ) -> ProjectedPartialIterator<Value, Base, Bytes, Output> {
    ProjectedPartialIterator(base: self, transform: transform)
  }

  @inlinable
  mutating func nextProjected<Output>(
    _ transform: (borrowing Value.View) throws -> Output
  ) throws -> PartialUpdate<Output>? {
    guard !self.terminated else { return nil }
    do {
      if let element = self.base.next() {
        try self.stream.next(self.bytes(element))
        return PartialUpdate(value: try self.stream.withView(transform), isComplete: false)
      }
      self.terminated = true
      return PartialUpdate(value: try self.stream.finishWithView(transform), isComplete: true)
    } catch {
      self.terminated = true
      throw error
    }
  }
}

/// A lazy projection that owns its source iterator and snapshots only its selected output.
public struct ProjectedPartialIterator<
  Root: StreamParseableRoot,
  Base: IteratorProtocol,
  Bytes: Sequence<UInt8>,
  Output
>: ~Copyable, PartialUpdateIteratorProtocol {
  @usableFromInline
  var base: PartialIterator<Root, Base, Bytes>
  @usableFromInline
  let transform: (borrowing Root.View) throws -> Output

  @inlinable
  init(
    base: consuming PartialIterator<Root, Base, Bytes>,
    transform: @escaping (borrowing Root.View) throws -> Output
  ) {
    self.base = base
    self.transform = transform
  }

  @inlinable
  public mutating func next() throws -> PartialUpdate<Output>? {
    try self.base.nextProjected(self.transform)
  }
}
