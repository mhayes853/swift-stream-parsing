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

// Container types the schema generator cannot route into. The macro decides an object from an
// array from a dictionary by syntax alone, so it sees `Deque<Int>` as an ordinary identifier and
// emits scalar cases that never fire. Conforming marks the type for the deprecated
// `_streamEnterField` overload, which turns that silence into a build warning.
public protocol _StreamUnroutableContainer {}
