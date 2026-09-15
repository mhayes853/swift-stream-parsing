// MARK: - Macros

/// Generates a ``StreamParseable`` conformance and `Partial` helper for a struct or enum.
///
/// ```swift
/// @StreamParseable struct Payload { var id: Int }
/// ```
///
/// An enum parses what `Codable` produces: `enum S: String` from `"live"`, `enum S: Int` from `5`,
/// and `enum S` from `{"live":{}}`, associated values keyed by label or `_0`, `_1`, .... Raw types
/// other than `String`, integers and floating point are diagnosed. Each enum names a fallback case
/// with ``StreamParseableDefault()`` or `StreamInitializable`. A partial `String`-raw value resolves
/// to the shortest case it prefixes (`live` may become `livestream`); `Partial.View.resolved` reads
/// whichever case has arrived so far.
@attached(
  extension,
  conformances: StreamParseable,
  names: named(Partial),
  named(init),
  named(streamValueOrInitial),
  arbitrary
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

/// Names the enum case a partial falls back to when the stream produced no representable value.
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
/// Supplies an enum's total ``StreamParseable/streamValueOrInitial(from:)``; strict still declines.
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
///
/// The macro reads the argument's spelling (`.optional`, `.streamInitialValue`), never its value,
/// so it must be written as one of the two cases.
public enum PartialMembersMode: Hashable, Sendable {
  /// The generated `Partial` exposes optional members and defaults them to `nil`.
  case optional

  /// Members are initialized to their ``StreamInitializable/streamInitialValue()`` result.
  case streamInitialValue
}
