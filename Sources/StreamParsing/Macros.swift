// MARK: - Macros

/// Generates a ``StreamParseable`` conformance and `Partial` helper for a struct.
/// Use this on value types that you want to decode incrementally from a byte stream.
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
public macro StreamParseableMember(key: String) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

/// Declares multiple key names that map to the same property when decoding.
///
/// ```swift
/// struct Payload {
///   @StreamParseableMember(keyNames: ["status", "state"])
///   var stage: String
/// }
/// ```
@attached(peer)
public macro StreamParseableMember(keyNames: [String]) =
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
  /// Members are initialized to their ``initialParseableValue()`` result.
  ///
  public static let initialParseableValue = Self()
}
