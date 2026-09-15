// An object partial with no members: it records that a `{...}` arrived and nothing about what was
// in it. This is the shape `Codable` gives an enum case with no associated values (`{"live":{}}`),
// so `@StreamParseable` lowers such an enum to one optional member of this type per case; which
// case arrived is which member is non-`nil`. Zero stored properties, so the whole partial is one
// byte per case. `.object`-shaped with no fields rather than schema-less, so `{"live":5}` is a
// type mismatch instead of being silently accepted.
public struct StreamEmptyObject: Sendable, Hashable, BitwiseCopyable {
  public init() {}
}

extension StreamEmptyObject: StreamInitializable {
  @inlinable
  public static func streamInitialValue() -> Self { Self() }
}

extension StreamEmptyObject: StreamParseableRoot {
  // No matcher, so every key inside the object routes to `.ignore` and is skipped whole rather
  // than reaching a closure that would answer -1 for it. See `StreamSchema.KeyRouting`.
  public static let streamSchema = StreamSchema(shape: .object)
}

extension StreamEmptyObject: StreamParseableObject {}

extension StreamEmptyObject: StreamParseable {
  public typealias Partial = Self
}
