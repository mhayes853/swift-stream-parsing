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
///
/// A generic struct, or a struct nested in a generic type, is supported; a generic enum is not.
/// A parameter a parsed property uses must be constrained to ``StreamParseable``. Its `Partial` is
/// not `Sendable`, because the members' partials are not known to be and a macro cannot add a
/// conditional conformance to a nested type; declare it where it holds:
///
/// ```swift
/// @StreamParseable struct Page<Item: StreamParseable> { var items: [Item] }
/// extension Page.Partial: Sendable where Item.Partial: Sendable {}
/// ```
///
/// A `null` for a property typed by the parameter is the parameter's own, so `Page<Int?>` reads
/// one as a present `nil`, as `Codable` does.
///
/// The generated schema is built once and kept in `schemaCache`, ``StreamSchemaCache/shared`` by
/// default. Name another stored instance to control those schemas' lifetime; it is evaluated
/// inside the generated `Partial`, so qualify it fully or use a leading dot (`Self` would name the
/// `Partial`):
///
/// ```swift
/// enum ToolSchemas { static let cache = StreamSchemaCache() }
///
/// @StreamParseable(schemaCache: ToolSchemas.cache) struct ToolCall { var name: String }
/// ```
///
/// A public generic type's schema property is `@inlinable`, so its cache must be `public` or
/// `@usableFromInline`. An enum with a raw type has no generated schema, and rejects the argument.
///
/// `keyDecodingStrategy` derives the key of each property, case and associated value label that
/// does not name its own with ``StreamParseableMember(key:initialCapacity:partialStrings:)``; see
/// ``StreamKeyDecodingStrategy``. A built-in strategy is applied as the macro expands, so its keys
/// are checked for collisions at compile time. Any other expression is evaluated when the schema is
/// built, like `schemaCache`. An enum with a raw type has no keys to convert, and rejects it.
///
/// `partialStrings` picks how the `Partial` stores the type's `String` members; see
/// ``PartialStringStorage``. `.string` stores them as Swift `String`s, trading append and snapshot
/// cost for a partial that reads like the model:
///
/// ```swift
/// @StreamParseable(partialStrings: .string)
/// struct Message {
///   var role: String      // Partial: String?
///   var tags: [String]    // Partial: StreamArray<String>?
/// }
/// ```
///
/// ``StreamParseableMember(partialStrings:)`` overrides it per member. Arrays and dictionaries stay
/// ``StreamArray`` and ``StreamDictionary`` either way. It reaches `String` leaves of each member's
/// own type, not the members of nested `@StreamParseable` types, which choose for themselves. An
/// enum applies it to its associated values; an enum with a raw type has none, and rejects it.
@attached(
  extension,
  conformances: StreamParseable,
  names: named(Partial),
  named(init),
  named(streamValueOrInitial),
  arbitrary
)
@attached(member, names: named(streamPartialValue))
public macro StreamParseable(
  partialMembers: PartialMembersMode = .optional,
  partialStrings: PartialStringStorage = .streamString,
  keyDecodingStrategy: StreamKeyDecodingStrategy = .useDefaultKeys,
  schemaCache: StreamSchemaCache = .shared
) =
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
public macro StreamParseableMember(
  key: String,
  initialCapacity: Int? = nil,
  partialStrings: PartialStringStorage? = nil
) =
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
public macro StreamParseableMember(
  keyNames: [String],
  initialCapacity: Int? = nil,
  partialStrings: PartialStringStorage? = nil
) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

/// Reserves storage when the parser first enters an array, dictionary, or string member.
///
/// The value is an expected element count for arrays and expected unique-key count for
/// dictionaries. For strings it is the expected decoded UTF-8 byte count, not the JSON wire byte
/// count. It is a performance hint, not a limit.
@attached(peer)
public macro StreamParseableMember(
  initialCapacity: Int,
  partialStrings: PartialStringStorage? = nil
) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

/// Overrides the type's `@StreamParseable(partialStrings:)` for one member.
///
/// ```swift
/// @StreamParseable(partialStrings: .string)
/// struct Message {
///   var role: String                                  // Partial: String?
///   @StreamParseableMember(partialStrings: .streamString)
///   var content: String                               // Partial: StreamString?
/// }
/// ```
///
/// Applies to every `String` leaf of the member's type, so `[String: [String]]` becomes
/// `StreamDictionary<StreamArray<String>>` under `.string`. A member with a `completedConversion:`
/// stores its strategy's `Source`, and rejects it.
@attached(peer)
public macro StreamParseableMember(partialStrings: PartialStringStorage) =
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

/// How a generated `Partial` stores the model's `String` members.
///
/// The macro reads the argument's spelling (`.streamString`, `.string`), never its value, so it
/// must be written as one of the two cases.
public enum PartialStringStorage: Hashable, Sendable {
  /// ``StreamString``, the default. Appends take raw UTF-8 and decode once at read; a snapshot
  /// shares sealed blocks, so an append after one copies at most the tail.
  case streamString

  /// Swift `String`. Each chunk is decoded into a `String` and appended, and an append after a
  /// snapshot copies the whole string, so reading every chunk of a long string is quadratic.
  /// Suited to short members, or to a partial read once at the end.
  case string
}

/// Converts a member's source representation once its JSON value completes.
///
/// ```swift
/// @StreamParseable struct Event {
///   @StreamParseableMember(completedConversion: UnixSeconds.self)
///   var createdAt: Date = Date(timeIntervalSince1970: 0)
/// }
/// ```
/// The strategy's `Value` must match the member's unwrapped type. The generated partial
/// stores `ConvertedPartial<Conversion>` and exposes incremental `source` and cached `value`.
/// Nonoptional members require an explicit default for `init(orInitial:)`. Null clears an
/// optional partial; use `observeField` to distinguish null from missing input. Capacity hints
/// are not supported on converted members.
/// - Parameter completedConversion: The two-way, completed-value conversion strategy.
@attached(peer)
public macro StreamParseableMember<Conversion: StreamCompletedValueConversion>(
  completedConversion: Conversion.Type
) = #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

/// Selects a JSON key and a completed-value conversion. See `StreamParseableMember(completedConversion:)`.
/// - Parameters:
///   - key: The JSON member name.
///   - completedConversion: The two-way conversion strategy for the member.
@attached(peer)
public macro StreamParseableMember<Conversion: StreamCompletedValueConversion>(
  key: String,
  completedConversion: Conversion.Type
) = #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

/// Selects JSON key aliases and a completed-value conversion.
/// - Parameters:
///   - keyNames: JSON names that route to the same member.
///   - completedConversion: The two-way conversion strategy for the member.
@attached(peer)
public macro StreamParseableMember<Conversion: StreamCompletedValueConversion>(
  keyNames: [String],
  completedConversion: Conversion.Type
) = #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")
