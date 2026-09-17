// MARK: - Generated conversion helpers
//
// What a macro-generated initializer is written out of, so the type checker supplies the target
// type. `typeOf` is never called but must stay: binding `T` to the declared type makes a wrong
// `partialTypeName` a compile error, not a silent misparse (the `[String?]` double-optional bug).
// A closure, not a `KeyPath`, for Embedded; an unwrapped member's argument promotes to `.some`.
extension StreamParseable {
  /// Strict: an absent member fails the whole conversion.
  @inline(__always)
  public static func _streamValue<T: StreamParseable>(
    _ typeOf: (Self) -> T,
    _ partial: T.Partial?
  ) -> T? {
    guard let partial else { return nil }
    return T(streamPartial: partial)
  }

  /// Total: an absent member falls back to its initial value, recursively.
  ///
  /// The fallback is on `T.Partial`, not `T`: every `Partial` is `StreamInitializable`, so any
  /// parseable member supplies its own default and this conversion is available on every type.
  @inline(__always)
  public static func _streamValueOrInitial<T: StreamParseable>(
    _ typeOf: (Self) -> T,
    _ partial: T.Partial?
  ) -> T {
    T.streamValueOrInitial(from: partial ?? T.Partial.streamInitialValue())
  }
}
