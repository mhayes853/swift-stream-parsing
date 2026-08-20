public struct StreamFrame {
  public var storage: UnsafeMutableRawPointer
  public var schema: StreamSchema
  public var pendingField: Int32

  public init(storage: UnsafeMutableRawPointer, schema: StreamSchema, pendingField: Int32 = -1) {
    self.storage = storage
    self.schema = schema
    self.pendingField = pendingField
  }
}

public final class StreamSchema: Sendable {
  public enum Shape: UInt8, Sendable {
    case object
    case array
    case dictionary
    case scalar

    // Whether a container of `kind` can be written through a destination of this shape. A JSON
    // object reaches both an object and a dictionary; every other pairing is a type mismatch.
    //
    // Without this a scalar destination accepts the contents of any container that reaches it,
    // because a scalar frame ignores keys and applies every token to itself: `[2,3]` arriving at
    // a `StreamDictionary<Int>` value wrote 2 and then 3 into it.
    public func canHold(container kind: Shape) -> Bool {
      switch (self, kind) {
      case (.object, .object), (.dictionary, .object), (.array, .array): true
      default: false
      }
    }
  }

  public let shape: Shape

  /// The field an apply closure receives when the destination *is* the value rather than a field
  /// of one — an array element, a dictionary value, a bare scalar root.
  ///
  /// Zero cannot say that, because zero is also the first field a generated object schema
  /// declares, and the two reached the same `applyString(storage, 0, bytes)`. An object arriving
  /// as an array element therefore absorbed a scalar into whichever member happened to be
  /// declared first: `["abc"]` into a `StreamArray<Person.Partial>` set `name` to "abc", and `[5]`
  /// was a type mismatch only because `name` could not hold a number.
  ///
  /// A negative field cannot collide with a declared one, so an object schema's
  /// `default: return false` turns those back into the mismatches they are. A scalar schema
  /// ignores the field either way and is unaffected.
  public static let wholeValueField = Int32(-1)

  // Where a key arriving at this schema has to go, precomputed into one byte.
  //
  // A schema call costs a closure load, a retain, an indirect call and a release — 17 ns against
  // 4.6 ns for a bare function pointer, measured in `SchemaDispatchBenchmarks` — and a schema with
  // no matcher spends all of it to reach `{ _ in -1 }`. That is not a rare case: the schema stood
  // up for a subtree the destination has no field for is this one, and 52% of `twitter.json`'s
  // 13,345 keys are inside such a subtree when parsed into a model that declares part of it, which
  // is what a model normally does.
  //
  // One byte rather than a `shape == .dictionary` test followed by a matcher test, because the
  // dictionary test was already on this path: routing the two questions through a single load and
  // a single switch is what keeps the schemas that *do* match from paying for the ones that do not.
  @usableFromInline
  enum KeyRouting: UInt8, Sendable {
    case match
    case dictionary
    case ignore
  }

  @usableFromInline let keyRouting: KeyRouting

  // Whether this schema declares no matcher. Read when one schema is wrapped in another, so the
  // wrapper does not install a matcher over a destination that has none.
  @usableFromInline let ignoresKeys: Bool

  // Returns the field identifier for a key, or -1 when the destination has no such field.
  public let matchField: @Sendable (Span<UInt8>) -> Int32

  // Each returns whether the token was actually applied. A field that matched a key but has no
  // destination for this kind of token returns false, which is what lets the sink tell a type
  // mismatch from a key the destination simply does not have. A bool return rather than a throw,
  // for the same reason the sink methods do not throw: a check after every call sits on the
  // hottest path.
  //
  // The field is a declared field's identifier when the schema stands over an object, and
  // ``wholeValueField`` when the destination *is* the value.
  public let applyString: @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>) -> Bool
  public let applyNumber: @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo) -> Bool
  public let applyBoolean: @Sendable (UnsafeMutableRawPointer, Int32, Bool) -> Bool
  public let applyNull: @Sendable (UnsafeMutableRawPointer, Int32) -> Bool

  // Returns a frame for the container stored at `field`, materializing it when absent. It is not
  // reset when present, so a key that repeats resumes the container the first occurrence built
  // rather than replacing it. `ContainerReentryTests` pins that, along with the scalar cases,
  // which do not agree with each other: a repeated string concatenates and a repeated number
  // replaces.
  public let enterField: @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame?

  // Appends an element and returns a frame for it. Arrays only.
  public let appendElement: @Sendable (UnsafeMutableRawPointer) -> StreamFrame?

  // Returns a frame for the value stored under a dynamic key. Dictionaries only.
  public let enterKey: @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> StreamFrame?

  // `matchField` is optional rather than defaulted so that "no matcher" is a fact the schema
  // carries rather than one indistinguishable from a matcher that happens to answer -1.
  public init(
    shape: Shape,
    matchField: (@Sendable (Span<UInt8>) -> Int32)? = nil,
    applyString: @escaping @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>) -> Bool = {
      _, _, _ in false
    },
    applyNumber: @escaping @Sendable (
      UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo
    ) -> Bool = { _, _, _, _ in false },
    applyBoolean: @escaping @Sendable (UnsafeMutableRawPointer, Int32, Bool) -> Bool = {
      _, _, _ in false
    },
    applyNull: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> Bool = { _, _ in false },
    enterField: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame? = { _, _ in nil },
    appendElement: @escaping @Sendable (UnsafeMutableRawPointer) -> StreamFrame? = { _ in nil },
    enterKey: @escaping @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> StreamFrame? = {
      _, _ in nil
    }
  ) {
    self.shape = shape
    self.ignoresKeys = matchField == nil
    // A dictionary routes keys through `enterKey` whether or not it also carries a matcher, which
    // is the order the sink already applied.
    self.keyRouting = shape == .dictionary ? .dictionary : (matchField == nil ? .ignore : .match)
    self.matchField = matchField ?? { _ in -1 }
    self.applyString = applyString
    self.applyNumber = applyNumber
    self.applyBoolean = applyBoolean
    self.applyNull = applyNull
    self.enterField = enterField
    self.appendElement = appendElement
    self.enterKey = enterKey
  }
}

// Anything that can describe its own routing, whatever shape it is.
//
// The macro resolves a field's shape through overloads, because it sees only syntax. That works
// where a concrete type is written and nowhere else: a function generic over `Value` cannot pick
// an overload on its behalf. `partials(of:from:)` is exactly such a function, so a root schema
// has to come from a protocol requirement rather than an overload.
//
// Kept separate from `StreamParseableObject` because the constrained `_streamEnterField` keys off
// that one, and it must not match a `String` field and hand it a frame instead of a scalar write.
public protocol StreamParseableRoot: StreamInitializable {
  static var streamSchema: StreamSchema { get }

  /// A borrowed window onto the value, for reading part of it without copying the whole.
  ///
  /// Defaults to the value itself, which is what a scalar wants: there is nothing to defer. A
  /// type with members worth reading one at a time overrides it with a projection whose accessors
  /// copy only what they return.
  associatedtype View: ~Copyable = Self

  /// Builds a view over a value at `storage`, which must outlive the view.
  static func streamView(_ storage: UnsafeMutableRawPointer) -> View
}

extension StreamParseableRoot {
  // A view of a value with nothing to project is the value, so reading it copies it. That copy is
  // a correct snapshot on its own: every container the parser writes into holds its open element
  // in an inline slot, so a copy shares only storage that is sealed and never written again, and
  // the open element's own buffers copy on write at the parser's next append. This is what
  // replaced a recursive `streamSnapshot()` rebuild.
  public static func streamView(_ storage: UnsafeMutableRawPointer) -> Self {
    storage.assumingMemoryBound(to: Self.self).pointee
  }
}

/// A partial that can receive an incoming container when stored as a field.
///
/// The entry operation lives on the resolved partial type, so aliases and generic wrappers do not
/// need to expose their shape in source syntax. A partial whose storage is described directly by
/// its ``StreamParseableRoot/streamSchema`` can use the default implementation.
public protocol StreamContainerPartial: StreamParseableRoot {
  /// The schema ``streamContainerFrame(at:schema:)`` installs.
  ///
  /// Separated from the frame so a caller can resolve it once and store it: `streamSchema` is a
  /// computed property on every generic partial, so reading it per entry allocates per container
  /// occurrence, and the schema built for one entry died with that entry's frame — the only
  /// schema in the system without a durable owner. The macro hoists this value into a
  /// `private static let` on the generated `Partial` and passes it back per entry.
  static var streamContainerSchema: StreamSchema { get }

  /// Returns the frame that writes a container into `storage`, carrying a resolved
  /// ``streamContainerSchema``.
  static func streamContainerFrame(
    at storage: UnsafeMutableRawPointer,
    schema: StreamSchema
  ) -> StreamFrame
}

extension StreamContainerPartial {
  @inlinable
  public static var streamContainerSchema: StreamSchema {
    Self.streamSchema
  }

  @inlinable
  public static func streamContainerFrame(
    at storage: UnsafeMutableRawPointer,
    schema: StreamSchema
  ) -> StreamFrame {
    StreamFrame(storage: storage, schema: schema)
  }
}

// Refines `StreamContainerPartial` so that a nested object field's schema is hoisted by its
// parent exactly as a container field's is. Without that the entry read `T.streamSchema` per
// occurrence, which is a stored static for a generated `Partial` and a freshly built schema for
// any hand-written conformance — `PersonNameComponents` is one — leaving the frame as its only
// owner. That is invisible while a frame retains its schema and fatal once a frame borrows it.
public protocol StreamParseableObject: StreamContainerPartial {}

// MARK: - Scalar schemas

// Shared by the root conformances below and by the macro's `_streamSchema(for:)` overloads, so
// the two cannot describe the same type differently.

@inlinable
public func _streamStringSchema<T: StreamStringConvertible>(_ type: T.Type) -> StreamSchema {
  StreamSchema(
    shape: .scalar,
    applyString: { storage, _, bytes in
      storage.assumingMemoryBound(to: T.self).pointee.streamAppend(utf8: bytes)
      return true
    }
  )
}

@inlinable
public func _streamNumberSchema<T: StreamNumberConvertible>(_ type: T.Type) -> StreamSchema {
  StreamSchema(
    shape: .scalar,
    applyNumber: { storage, _, bytes, info in
      // A token that does not fit the destination is a rejection, not a silent no-op, which is
      // what reports an overflow.
      guard let parsed = T(streamParsing: bytes, info: info) else { return false }
      storage.assumingMemoryBound(to: T.self).pointee = parsed
      return true
    }
  )
}

@inlinable
public func _streamBooleanSchema<T: StreamBooleanConvertible>(_ type: T.Type) -> StreamSchema {
  StreamSchema(
    shape: .scalar,
    applyBoolean: { storage, _, value in
      storage.assumingMemoryBound(to: T.self).pointee = T(streamParsingBoolean: value)
      return true
    }
  )
}

// MARK: - Container schemas

@inlinable
public func _streamArraySchema<Element: StreamInitializable>(
  _ type: Element.Type,
  element: StreamSchema
) -> StreamSchema {
  StreamSchema(
    shape: .array,
    appendElement: { storage in
      _streamOpenElement(
        in: &storage.assumingMemoryBound(to: StreamArray<Element>.self).pointee,
        initial: Element.streamInitialValue(),
        schema: element
      )
    }
  )
}

@inlinable
public func _streamDictionarySchema<Value: StreamInitializable>(
  _ type: Value.Type,
  value valueSchema: StreamSchema
) -> StreamSchema {
  StreamSchema(
    shape: .dictionary,
    enterKey: { storage, key in
      _streamEnterDictionaryValue(
        &storage.assumingMemoryBound(to: StreamDictionary<Value>.self).pointee,
        key: key,
        initial: Value.streamInitialValue(),
        schema: valueSchema
      )
    }
  )
}

// MARK: - Root conformances

extension StreamParseableRoot where Self: StreamStringConvertible {
  public static var streamSchema: StreamSchema { _streamStringSchema(Self.self) }
}

extension StreamParseableRoot where Self: StreamNumberConvertible {
  public static var streamSchema: StreamSchema { _streamNumberSchema(Self.self) }
}

extension StreamParseableRoot where Self: StreamBooleanConvertible {
  public static var streamSchema: StreamSchema { _streamBooleanSchema(Self.self) }
}
