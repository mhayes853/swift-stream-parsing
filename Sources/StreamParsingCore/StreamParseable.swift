/// A value that can expose the partial parsing state consumed from a stream.
///
/// You typically do not conform to ``StreamParseable`` directly; instead add the
/// `@StreamParseable` macro to your struct and let it synthesize the conformance.
public protocol StreamParseable {
  /// The partial representation exposed during parsing.
  ///
  /// Defaults to `Self`, for scalars whose partial is the value itself; the `where Partial == Self`
  /// extension below supplies all three members.
  associatedtype Partial: StreamParseableRoot = Self

  /// The partial state that corresponds to the type’s incremental parsing representation.
  var streamPartialValue: Partial { get }

  /// The strict inverse of ``streamPartialValue``: `nil` when the partial is not complete
  /// enough to describe a whole value.
  ///
  /// A member the stream never produced fails, as does one the type cannot represent (a raw value
  /// outside an enum's cases). A member the type declares optional converts to `nil`.
  init?(streamPartial: Partial)

  /// The total inverse of ``streamPartialValue``: members the stream never produced fall back
  /// to their initial values, recursively.
  ///
  /// Only absent members default, so a partial carrying just an `id` converts to a value with that
  /// `id`. A type with members implements this member-wise; the blanket default below discards the
  /// whole value when any part is missing.
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

// The fallback for a partial with nothing worth preserving piecewise (a scalar, or an enum with a
// default case). A type with members must not take this: it discards every member that arrived.
// These defaults are `@inlinable` so a conformance in another module specializes them rather than
// calling the generic entry point with witness tables.
extension StreamParseable where Self: StreamInitializable {
  @inlinable
  public static func streamValueOrInitial(from partial: Partial) -> Self {
    Self(streamPartial: partial) ?? Self.streamInitialValue()
  }
}

extension StreamParseable
where Self: RawRepresentable, RawValue: StreamParseable, Partial == RawValue.Partial {
  @inlinable
  public var streamPartialValue: Partial {
    self.rawValue.streamPartialValue
  }

  // An uncovered raw value is exactly the failure the strict conversion reports. An enum that would
  // rather default conforms to `StreamInitializable`, picking up the fallback above.
  @inlinable
  public init?(streamPartial: Partial) {
    guard let rawValue = RawValue(streamPartial: streamPartial),
      let value = Self(rawValue: rawValue)
    else {
      return nil
    }
    self = value
  }
}
