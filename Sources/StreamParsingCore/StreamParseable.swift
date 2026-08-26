/// A value that can expose the partial parsing state consumed from a stream.
///
/// You typically do not conform to ``StreamParseable`` directly; instead add the
/// `@StreamParseable` macro to your struct and let it synthesize the conformance.
public protocol StreamParseable {
  /// The partial representation exposed during parsing.
  associatedtype Partial: StreamParseableRoot

  /// The partial state that corresponds to the type’s incremental parsing representation.
  var streamPartialValue: Partial { get }

  /// The strict inverse of ``streamPartialValue``: `nil` when the partial is not complete
  /// enough to describe a whole value.
  ///
  /// A member the stream never produced fails the conversion, and so does a member the type
  /// cannot represent — a raw value outside an enum's cases, say. A member the type *declares*
  /// as optional does not: absence is representable there, so it converts to `nil`.
  init?(streamPartial: Partial)

  /// The total inverse of ``streamPartialValue``: members the stream never produced fall back
  /// to their initial values, recursively.
  ///
  /// This preserves what did arrive. Only the absent members default, so a partial carrying an
  /// `id` and nothing else converts to a value with that `id` and defaults elsewhere — which is
  /// why a type with members implements this member-wise rather than taking the blanket default
  /// below, which discards the whole value when any part of it is missing.
  static func streamValueOrInitial(from partial: Partial) -> Self
}

extension StreamParseable where Partial == Self {
  public var streamPartialValue: Partial {
    self
  }

  public init?(streamPartial: Partial) {
    self = streamPartial
  }

  public static func streamValueOrInitial(from partial: Partial) -> Self {
    partial
  }
}

// The fallback for a type whose partial carries nothing worth preserving piecewise — a scalar, or
// an enum that names a default case. A type with members must not take this: it throws away every
// member that *did* arrive as soon as one is missing.
extension StreamParseable where Self: StreamInitializable {
  public static func streamValueOrInitial(from partial: Partial) -> Self {
    Self(streamPartial: partial) ?? Self.streamInitialValue()
  }
}

extension StreamParseable
where Self: RawRepresentable, RawValue: StreamParseable, Partial == RawValue.Partial {
  public var streamPartialValue: Partial {
    self.rawValue.streamPartialValue
  }

  // A raw value the case list does not cover is exactly the "cannot represent it" failure the
  // strict conversion exists to report. An enum that would rather default than fail says so by
  // conforming to `StreamInitializable`, which picks up the fallback above.
  public init?(streamPartial: Partial) {
    guard let rawValue = RawValue(streamPartial: streamPartial),
      let value = Self(rawValue: rawValue)
    else {
      return nil
    }
    self = value
  }
}
