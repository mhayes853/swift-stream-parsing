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

// MARK: - Enum case discriminator

/// `_streamCase` after a write to case `index` of a raw-less enum's `Partial`: `index` while no
/// other case can be set, `-1` while none is, and `-2` once two may be, which sends a reader back
/// to counting the members. The invariant is only ever "no *other* case is set": a `null` can
/// still clear case `index` itself.
@inlinable
@inline(__always)
public func _streamEnumCaseAfterWrite(_ current: Int32, case index: Int32, present: Bool) -> Int32 {
  if present { return current == -1 || current == index ? index : -2 }
  return current == index ? -1 : current
}

/// The optional-object route `_streamFieldRoute` gives a case member, whose `prepare` also records
/// the case in `_streamCase`, `discriminatorOffset` bytes into the partial. Mirrors
/// `_streamOptionalContainerPrepare` rather than wrapping it, so an entry stays one closure call.
@inlinable
public func _streamEnumCaseRoute<Root, T: StreamParseableObject>(
  _ member: inout T?,
  in base: UnsafeMutablePointer<Root>,
  schema: StreamSchema?,
  case index: Int32,
  discriminatorOffset: Int
) -> StreamFieldRoute {
  let delta = discriminatorOffset - _streamFieldOffset(&member, in: base)
  let owner = _streamOwnedTemplate(T?.some(T.streamInitialValue()))
  nonisolated(unsafe) let template = owner.address(as: T?.self)
  let inner = T._streamContainerPrepare
  return StreamFieldRoute(
    .container, optional: true, schema: schema,
    prepare: { [owner] storage, _ in
      _ = owner
      let pointer = storage.assumingMemoryBound(to: T?.self)
      if pointer.pointee == nil {
        _streamCopyInitialize(pointer, from: template)
      }
      inner?(storage, 0)
      let tag = (storage + delta).assumingMemoryBound(to: Int32.self)
      tag.pointee = _streamEnumCaseAfterWrite(tag.pointee, case: index, present: true)
    }
  )
}

// MARK: - Helpers

/// Controls how the generated partial struct initializes its properties.
public struct PartialMembersMode: Sendable {
  /// The generated `Partial` exposes optional members and defaults them to `nil`.
  public static let optional = Self()

  /// Members are initialized to their ``StreamInitializable/streamInitialValue()`` result.
  public static let streamInitialValue = Self()
}
