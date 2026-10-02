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

  /// Strict, for a member the partial stores as the model spells it (`partialStrings: .string`):
  /// nothing to convert, so only absence fails. The macro maps a container's storage to the
  /// member's type before the call; binding `T` still makes a wrong storage spelling a compile error.
  @inline(__always)
  public static func _streamStoredValue<T>(_ typeOf: (Self) -> T, _ stored: T?) -> T? {
    stored
  }

  /// Total: an absent stored member falls back to `initial`, which the macro writes as the member
  /// type's empty value (`""`, `[]`, `[:]`, `nil`).
  @inline(__always)
  public static func _streamStoredValue<T>(
    _ typeOf: (Self) -> T,
    _ stored: T?,
    orInitial initial: @autoclosure () -> T
  ) -> T {
    stored ?? initial()
  }
}
