// MARK: - Generated conversion helpers
//
// The two entry points a macro-generated initializer is written out of. Both exist so the *type
// checker* supplies the destination type rather than the macro re-deriving it from syntax.
//
// **`typeOf` is never called and must not be deleted.** Its only job is to bind `T` to the declared
// type of the property being filled, so the macro spells nothing but `Self` and a property name,
// and so the macro's own `Partial` derivation is checked against the compiler's `T.Partial` — a
// mistake in `partialTypeName` becomes a compile error instead of a silent misparse. (A second
// derivation here is where the `[String?]` double-optional bug came from.)
//
// A closure, not a `KeyPath`: key paths do not lower under Embedded Swift. Both take `T.Partial?`,
// which lets one signature serve every member shape — where the macro did not wrap the member the
// argument promotes to `.some` and absence is correctly not expressible.
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
  /// Note the fallback is on `T.Partial`, not on `T`: every `Partial` is a `StreamParseableRoot`
  /// and therefore `StreamInitializable`, so any parseable member can supply its own default
  /// without conforming to anything further. That is what keeps this conversion available on
  /// every type rather than on an opt-in subset.
  @inline(__always)
  public static func _streamValueOrInitial<T: StreamParseable>(
    _ typeOf: (Self) -> T,
    _ partial: T.Partial?
  ) -> T {
    T.streamValueOrInitial(from: partial ?? T.Partial.streamInitialValue())
  }
}
