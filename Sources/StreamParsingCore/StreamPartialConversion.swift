// MARK: - Generated conversion helpers
//
// The two entry points a macro generated initializer is written out of. Both exist so the *type
// checker* supplies the destination type, rather than the macro re-deriving it from syntax.
//
// `typeOf` is never called. Its only job is to bind `T` to the declared type of the property
// being filled, which buys two things:
//
//   - The macro spells nothing but `Self` and a property name. It already derives a member type
//     once, for `Partial`; deriving the same type a second time here is where `[String?]` and the
//     double-optional bug came from, and neither derivation can go wrong if there is only one.
//   - The two derivations are checked against each other. `T` comes from the property, `T.Partial`
//     from the compiler, and the member the macro emitted has to match it — so a mistake in
//     `partialTypeName` is a compile error at the call site instead of a silent misparse.
//
// It is a closure rather than a `KeyPath` because key paths do not lower under Embedded Swift.
// Both forms optimize away completely once specialized, so this costs nothing at runtime; a key
// path would have cost nothing either, and then failed to link on a microcontroller.
//
// Both take `T.Partial?`, which is what lets one signature serve every member shape. Where the
// macro wrapped a member because the mode asked for optional members, the argument matches
// directly and absence is visible. Where it did not — a `.streamInitialValue` member, or a
// property the user declared optional, whose `T.Partial` is already an `Optional` — the argument
// promotes to `.some` and absence is not expressible, which is correct in both cases.
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
