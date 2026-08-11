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

public protocol StreamParseableObject {
  static var streamSchema: StreamSchema { get }
  static func streamInitialValue() -> Self
}
