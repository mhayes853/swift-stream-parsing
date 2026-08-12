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

  public var applyString: @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>) -> Void
  public var applyNumber: @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo) -> Void
  public var applyBoolean: @Sendable (UnsafeMutableRawPointer, Int32, Bool) -> Void
  public var applyNull: @Sendable (UnsafeMutableRawPointer, Int32) -> Void

  // Resets the container stored at `field` and returns a frame for it.
  public var enterField: @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame?

  // Appends an element and returns a frame for it. Arrays only.
  public var appendElement: @Sendable (UnsafeMutableRawPointer) -> StreamFrame?

  // Returns a frame for the value stored under a dynamic key. Dictionaries only.
  public var enterKey: @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> StreamFrame?

  public init(
    shape: Shape,
    matchField: @escaping @Sendable (Span<UInt8>) -> Int32 = { _ in -1 },
    applyString: @escaping @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>) -> Void = { _, _, _ in },
    applyNumber: @escaping @Sendable (
      UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo
    ) -> Void = { _, _, _, _ in },
    applyBoolean: @escaping @Sendable (UnsafeMutableRawPointer, Int32, Bool) -> Void = { _, _, _ in },
    applyNull: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> Void = { _, _ in },
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
    }
  )
}

@inlinable
public func _streamNumberSchema<T: StreamNumberConvertible>(_ type: T.Type) -> StreamSchema {
  StreamSchema(
    shape: .scalar,
    applyNumber: { storage, _, bytes, info in
      guard let parsed = T(streamParsing: bytes, info: info) else { return }
      storage.assumingMemoryBound(to: T.self).pointee = parsed
    }
  )
}

@inlinable
public func _streamBooleanSchema<T: StreamBooleanConvertible>(_ type: T.Type) -> StreamSchema {
  StreamSchema(
    shape: .scalar,
    applyBoolean: { storage, _, value in
      storage.assumingMemoryBound(to: T.self).pointee = T(streamParsingBoolean: value)
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
