/// The default ``StreamParseableRoot/View`` for a type with nothing to project — a scalar, or any
/// other type that hands its whole value back rather than a member-by-member window onto it.
///
/// With the `LifetimeView` trait, the view is `~Escapable` and the compiler ties it to the storage
/// it was built from. Otherwise it is escapable and explicitly unsafe: the caller is responsible
/// for ensuring the storage remains alive and unmoved for every access.
#if LifetimeView
public struct StreamPointerView<Value>: ~Copyable, ~Escapable {
  @usableFromInline let storage: UnsafeMutablePointer<Value>

  @_lifetime(borrow storage)
  public init(_ storage: UnsafeMutableRawPointer) {
    self.storage = storage.assumingMemoryBound(to: Value.self)
  }

  @inlinable
  public var value: Value { self.storage.pointee }
}
#else
@unsafe
public struct StreamPointerView<Value>: ~Copyable {
  @usableFromInline let storage: UnsafeMutablePointer<Value>

  public init(_ storage: UnsafeMutableRawPointer) {
    self.storage = storage.assumingMemoryBound(to: Value.self)
  }

  @inlinable
  public var value: Value { self.storage.pointee }
}
#endif

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
