// An object partial with no members: it records that a `{...}` arrived and nothing about what was
// in it.
//
// This exists for the shape Swift's own `Codable` synthesis gives an enum case that carries no
// associated values. `enum Stage { case unknown, live }` encodes as `{"live":{}}` — the case name
// is a key and its value is an empty object — so `@StreamParseable` lowers such an enum to an
// object partial with one optional member per case, each of this type. Which case arrived is then
// exactly which member is non-`nil`, and that question is already answered by machinery the
// parser has: entering a container materialises the member it is entered through, empty or not.
//
// Zero stored properties, so an `Optional<StreamEmptyObject>` member is one byte and an enum's
// whole partial is one byte per case.
//
// It is `.object`-shaped with no fields, which is not the same as having no schema: the shape is
// what makes `{"live":5}` and `{"live":[]}` type mismatches rather than silently accepted, since
// `Shape.canHold(container:)` admits only an object and every scalar apply answers `.unsupported`.
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
