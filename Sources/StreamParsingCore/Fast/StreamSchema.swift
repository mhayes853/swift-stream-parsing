// Static routing description for a value. Every member is a non-capturing closure, so it is a
// thin function pointer: no context allocation, no existential, no metatype.

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

public struct StreamSchema: @unchecked Sendable {
  public enum Shape: UInt8, Sendable {
    case object
    case array
    case dictionary
    case scalar
  }

  public var shape: Shape

  // Returns the field identifier for a key, or -1 when the destination has no such field.
  public var matchField: @Sendable (Span<UInt8>) -> Int32

  // Each returns whether the token was actually applied. A field that matched a key but has no
  // destination for this kind of token returns false, which is what lets the sink tell a type
  // mismatch from a key the destination simply does not have. A bool return rather than a throw,
  // for the same reason the sink methods do not throw: a check after every call sits on the
  // hottest path.
  public var applyString: @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>) -> Bool
  public var applyNumber: @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo) -> Bool
  public var applyBoolean: @Sendable (UnsafeMutableRawPointer, Int32, Bool) -> Bool
  public var applyNull: @Sendable (UnsafeMutableRawPointer, Int32) -> Bool

  // Resets the container stored at `field` and returns a frame for it.
  public var enterField: @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame?

  // Appends an element and returns a frame for it. Arrays only.
  public var appendElement: @Sendable (UnsafeMutableRawPointer) -> StreamFrame?

  // Returns a frame for the value stored under a dynamic key. Dictionaries only.
  public var enterKey: @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> StreamFrame?

  public init(
    shape: Shape,
    matchField: @escaping @Sendable (Span<UInt8>) -> Int32 = { _ in -1 },
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
    self.matchField = matchField
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

  /// A copy that shares no storage with the value being parsed, and so is safe to keep.
  ///
  /// The sink writes container elements through a raw pointer, which never triggers copy on
  /// write. A value handed out while parsing continues therefore shares the buffer being written
  /// into, and changes after the fact. Rebuilding those buffers is what makes a kept value a
  /// snapshot of the moment rather than a window onto the present.
  func streamSnapshot() -> Self

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
  // A view of a value with nothing to project is the value. Containers land here too, so reading
  // one through a view snapshots it, which is the only safe thing to hand back.
  public static func streamView(_ storage: UnsafeMutableRawPointer) -> Self {
    storage.assumingMemoryBound(to: Self.self).pointee.streamSnapshot()
  }
}

extension StreamParseableRoot {
  // Correct for scalars, and for structs whose members are all inline: copying one already gives
  // it storage of its own, and a later write goes through copy on write as usual. Only types
  // that put values in a heap buffer need to override this.
  public func streamSnapshot() -> Self { self }
}

public protocol StreamParseableObject: StreamParseableRoot {}

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
      _streamAppendElement(
        to: &storage.assumingMemoryBound(to: [Element].self).pointee,
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
