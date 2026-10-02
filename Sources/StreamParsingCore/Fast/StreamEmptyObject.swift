// An object partial with no members, recording only that a `{...}` arrived: the shape `Codable`
// gives an enum case without associated values (`{"live":{}}`), which `@StreamParseable` lowers to
// one optional member of this type per case. `.object`-shaped rather than schema-less, so
// `{"live":5}` is a type mismatch.
public struct StreamEmptyObject: Sendable, Hashable, BitwiseCopyable {
  public init() {}
}

extension StreamEmptyObject: StreamInitializable {
  @inlinable
  public static func streamInitialValue() -> Self { Self() }
}

extension StreamEmptyObject: StreamParseableRoot {
  // No matcher, so every key routes to `.ignore` and is skipped whole. See
  // `StreamSchema.KeyRouting`.
  public static let streamSchema = StreamSchema(shape: .object)
}

extension StreamEmptyObject: StreamParseableObject {}

extension StreamEmptyObject: StreamParseable {
  public typealias Partial = Self
}
