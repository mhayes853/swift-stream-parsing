// MARK: - Macros

/// Generates a ``StreamParseable`` conformance and `Partial` helper for a struct or enum.
///
/// ```swift
/// @StreamParseable
/// struct Payload {
///   var id: Int
///   var body: String
/// }
/// ```
///
/// ## Enums
///
/// An enum is lowered by how it is spelled, and each form parses what `Codable` produces for the
/// same declaration:
///
/// | spelling | JSON | `Partial` |
/// | --- | --- | --- |
/// | `enum S: String` | `"live"` | `StreamString` |
/// | `enum S: Int` | `5` | `Int` |
/// | `enum S` (no raw type) | `{"live":{}}` | a generated struct |
///
/// Every enum must name the case a total conversion falls back to, with
/// ``StreamParseableDefault()`` or by conforming to `StreamInitializable`.
///
/// Cases with associated values are not supported. Only `String` and the standard integer and
/// floating point types are recognised as raw types; an enum with any other raw type is
/// diagnosed rather than silently given the object form.
///
/// A `String`-raw case resolves from a *partial* value as the shortest case those bytes are still
/// a prefix of, because a string arrives in pieces and carries no end signal. A case can
/// therefore be superseded as more bytes land — `live` becoming `livestream` — where a number or
/// an object key, both of which arrive whole, cannot.
@attached(
  extension,
  conformances: StreamParseable,
  names: named(Partial),
  named(init),
  named(streamValueOrInitial)
)
@attached(member, names: named(streamPartialValue))
public macro StreamParseable(partialMembers: PartialMembersMode = .optional) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMacro")

/// Declares a custom key name for the property inside the generated `Partial`.
///
/// ```swift
/// struct Payload {
///   @StreamParseableMember(key: "user_id")
///   var id: Int
/// }
/// ```
@attached(peer)
public macro StreamParseableMember(key: String, initialCapacity: Int? = nil) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

/// Declares multiple key names that map to the same property when parsing.
///
/// ```swift
/// struct Payload {
///   @StreamParseableMember(keyNames: ["status", "state"])
///   var stage: String
/// }
/// ```
@attached(peer)
public macro StreamParseableMember(keyNames: [String], initialCapacity: Int? = nil) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

/// Reserves storage when the parser first enters an array, dictionary, or string member.
///
/// The value is an expected element count for arrays and expected unique-key count for
/// dictionaries. For strings it is the expected decoded UTF-8 byte count, not the JSON wire byte
/// count. It is a performance hint, not a limit.
@attached(peer)
public macro StreamParseableMember(initialCapacity: Int) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

/// Names the enum case a partial falls back to when the stream produced no value the enum can
/// represent.
///
/// ```swift
/// @StreamParseable
/// enum Stage: String {
///   @StreamParseableDefault
///   case unknown
///   case live
/// }
/// ```
///
/// This is what supplies ``StreamParseable/streamValueOrInitial(from:)`` — the total conversion —
/// for an enum. Without it the enum must conform to ``StreamInitializable`` instead, which names
/// the same fallback in longhand. The strict conversion still declines: only the total one
/// substitutes the default.
@attached(peer)
public macro StreamParseableDefault() =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableDefaultMacro")

/// Marks a stored property as ignored when deriving the `Partial`.
///
/// ```swift
/// struct Payload {
///   @StreamParseableIgnored
///   var transientState: String?
/// }
/// ```
@attached(peer)
public macro StreamParseableIgnored() =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableIgnoredMacro")

// MARK: - Helpers

/// Controls how the generated partial struct initializes its properties.
public struct PartialMembersMode: Sendable {
  /// The generated `Partial` exposes optional members and defaults them to `nil`.
  public static let optional = Self()

  /// Members are initialized to their ``StreamInitializable/streamInitialValue()`` result.
  public static let streamInitialValue = Self()
}
