/// The default ``StreamParseableRoot/View`` for a type with nothing to project — a scalar, or any
/// other type that hands its whole value back rather than a member-by-member window onto it.
///
/// Reading it still costs one dereference (``value``), same as the old `View == Self` default
/// did implicitly. What changes is that the dereference is deferred to the read rather than
/// happening the moment the view is built, and the view itself is `~Escapable`: the compiler
/// ties it to the call that produced it, the same way every other ``StreamParseableRoot/View``
/// is tied to its `storage`, instead of trusting a caller not to move it elsewhere.
public struct StreamPointerView<Value>: ~Copyable, ~Escapable {
  @usableFromInline let storage: UnsafeMutablePointer<Value>

  @_lifetime(borrow storage)
  public init(_ storage: UnsafeMutableRawPointer) {
    self.storage = storage.assumingMemoryBound(to: Value.self)
  }

  @inlinable
  public var value: Value { self.storage.pointee }
}

#if compiler(>=6.4)
extension StreamPointerView: Equatable where Value: Equatable {
  @inlinable
  public static func == (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
    lhs.value == rhs.value
  }

  // So `view.count == 5` reads without an explicit `.value`.
  @inlinable
  public static func == (lhs: borrowing Self, rhs: Value) -> Bool { lhs.value == rhs }
}

extension StreamPointerView: Comparable where Value: Comparable {
  @inlinable
  public static func < (lhs: borrowing Self, rhs: borrowing Self) -> Bool {
    lhs.value < rhs.value
  }
}
#endif
