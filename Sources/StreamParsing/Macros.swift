// MARK: - Macros

/// Generates a ``StreamParseable`` conformance and `Partial` helper for a struct.
///
/// ```swift
/// @StreamParseable
/// struct Payload {
///   var id: Int
///   var body: String
/// }
/// ```
@attached(extension, conformances: StreamParseable, names: named(Partial))
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

/// Reserves storage when the parser first enters an array or dictionary member.
///
/// The value is an expected element count for arrays and expected unique-key count for
/// dictionaries. It is a performance hint, not a limit.
@attached(peer)
public macro StreamParseableMember(initialCapacity: Int) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

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
