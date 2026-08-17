// MARK: - Conversion protocols

extension String: StreamStringConvertible {
  public static func streamInitialValue() -> Self { "" }

  public mutating func streamAppend(utf8 bytes: Span<UInt8>) {
    bytes.withUnsafeBufferPointer { buffer in
      self += String(decoding: buffer, as: UTF8.self)
    }
  }

  public mutating func streamReserve(utf8ByteCount: Int) {
    self.reserveCapacity(utf8ByteCount)
  }
}

extension Bool: StreamBooleanConvertible, StreamInitializable {
  public init(streamParsingBoolean value: Bool) { self = value }
  public static func streamInitialValue() -> Self { false }
}

extension Optional: StreamNullable, StreamInitializable {
  public static func streamNullValue() -> Self { nil }
  public static func streamInitialValue() -> Self { nil }
}

extension Array: StreamInitializable {
  public static func streamInitialValue() -> Self { [] }
}

extension Int: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension Int8: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension Int16: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension Int32: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension Int64: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension UInt: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension UInt8: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension UInt16: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension UInt32: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension UInt64: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension Double: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}
extension Float: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }
}

// Root conformances. Each one picks up the schema its conversion protocol implies, so a document
// that is a bare scalar, an array or a dictionary parses into the same shapes a field would.

extension String: StreamParseableRoot {}
extension Bool: StreamParseableRoot {}
extension Int: StreamParseableRoot {}
extension Int8: StreamParseableRoot {}
extension Int16: StreamParseableRoot {}
extension Int32: StreamParseableRoot {}
extension Int64: StreamParseableRoot {}
extension UInt: StreamParseableRoot {}
extension UInt8: StreamParseableRoot {}
extension UInt16: StreamParseableRoot {}
extension UInt32: StreamParseableRoot {}
extension UInt64: StreamParseableRoot {}
extension Double: StreamParseableRoot {}
extension Float: StreamParseableRoot {}

// `Array` is a bridging destination rather than a parse target. Parsing into one means writing
// elements through a raw pointer into a buffer other values can be sharing, which is what made
// kept states change after the fact; `StreamArray` exists so that path does not exist.

extension StreamDictionary: StreamParseableRoot, StreamContainerPartial
where Value: StreamParseableRoot {
  public static var streamSchema: StreamSchema {
    _streamDictionarySchema(Value.self, value: Value.streamSchema)
  }
}

// The accumulator carries magnitude in a UInt64, so a value wider than that arrives flagged as
// overflowed with nothing usable in it. The registration based parser scanned the token for
// these two types, so taking the shared conversion unchanged would narrow their range to 64
// bits. They re-scan instead, which only happens for tokens that actually need it.

@available(StreamParsing128BitIntegers, *)
extension Int128: StreamNumberConvertible, StreamInitializable, StreamParseableRoot {
  public static func streamInitialValue() -> Self { 0 }

}

@available(StreamParsing128BitIntegers, *)
extension UInt128: StreamNumberConvertible, StreamInitializable, StreamParseableRoot {
  public static func streamInitialValue() -> Self { 0 }

}

// MARK: - String

extension String: StreamParseable {
  public typealias Partial = Self
}

// MARK: - Double

extension Double: StreamParseable {
  public typealias Partial = Self
}

// MARK: - Float

extension Float: StreamParseable {
  public typealias Partial = Self
}

// MARK: - Bool

extension Bool: StreamParseable {
  public typealias Partial = Self
}

// MARK: - Int8

extension Int8: StreamParseable {
  public typealias Partial = Self
}

// MARK: - Int16

extension Int16: StreamParseable {
  public typealias Partial = Self
}

// MARK: - Int32

extension Int32: StreamParseable {
  public typealias Partial = Self
}

// MARK: - Int64

extension Int64: StreamParseable {
  public typealias Partial = Self
}

// MARK: - Int

extension Int: StreamParseable {
  public typealias Partial = Self
}

// MARK: - UInt8

extension UInt8: StreamParseable {
  public typealias Partial = Self
}

// MARK: - UInt16

extension UInt16: StreamParseable {
  public typealias Partial = Self
}

// MARK: - UInt32

extension UInt32: StreamParseable {
  public typealias Partial = Self
}

// MARK: - UInt64

extension UInt64: StreamParseable {
  public typealias Partial = Self
}

// MARK: - UInt

extension UInt: StreamParseable {
  public typealias Partial = Self
}

// MARK: - Int128

@available(StreamParsing128BitIntegers, *)
extension Int128: StreamParseable {
  public typealias Partial = Self
}

// MARK: - UInt128

@available(StreamParsing128BitIntegers, *)
extension UInt128: StreamParseable {
  public typealias Partial = Self
}

// MARK: - Array

extension Array: StreamParseable where Element: StreamParseable {
  public typealias Partial = StreamArray<Element.Partial>

  public var streamPartialValue: StreamArray<Element.Partial> {
    StreamArray(self.lazy.map(\.streamPartialValue))
  }
}

// MARK: - Dictionary

// A dictionary's partial is a StreamDictionary, matching what the macro emits for a dictionary
// member: Dictionary relocates its values on insertion, so there is no address for a frame to
// write a nested value through.
extension Dictionary: StreamParseable where Key == String, Value: StreamParseable {
  public typealias Partial = StreamDictionary<Value.Partial>

  public var streamPartialValue: StreamDictionary<Value.Partial> {
    var partial = StreamDictionary<Value.Partial>()
    for key in self.keys.sorted() {
      partial.updateValue(self[key]!.streamPartialValue, forKey: key)
    }
    return partial
  }
}

// MARK: - Optional

extension Optional: StreamParseable where Wrapped: StreamParseable {
  public typealias Partial = Wrapped.Partial?

  public var streamPartialValue: Wrapped.Partial? {
    switch self {
    case .none: nil
    case .some(let wrapped): wrapped.streamPartialValue
    }
  }
}

// An optional destination materializes before it delegates, so `Int?` accepts what `Int` accepts
// and a null still clears it. The payload sits at offset zero, the same assumption the frame
// entry helpers rely on.
extension Optional: StreamParseableRoot where Wrapped: StreamParseableRoot {
  // The wrapped schema is resolved once and captured, not read inside each closure.
  //
  // `Wrapped.streamSchema` is a computed property for every scalar and container root — it builds
  // a fresh `StreamSchema` on each access, since a stored static cannot be declared in a generic
  // type or a protocol extension. Reading it inside the closures therefore allocated one per
  // *token* routed through an optional destination, rather than one per schema. Capturing it here
  // is what makes the delegation cost a call.
  public static var streamSchema: StreamSchema {
    let wrapped = Wrapped.streamSchema
    return StreamSchema(
      shape: wrapped.shape,
      matchField: { key in wrapped.matchField(key) },
      applyString: { storage, field, bytes in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.applyString(storage, field, bytes)
      },
      applyNumber: { storage, field, bytes, info in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.applyNumber(storage, field, bytes, info)
      },
      applyBoolean: { storage, field, value in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.applyBoolean(storage, field, value)
      },
      applyNull: { storage, _ in
        storage.assumingMemoryBound(to: Wrapped?.self).pointee = nil
        return true
      },
      enterField: { storage, field in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.enterField(storage, field)
      },
      appendElement: { storage in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.appendElement(storage)
      },
      enterKey: { storage, key in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.enterKey(storage, key)
      }
    )
  }
}

extension Optional: StreamContainerPartial where Wrapped: StreamContainerPartial {
  public static func streamContainerFrame(
    at storage: UnsafeMutableRawPointer
  ) -> StreamFrame {
    _streamMaterializeOptional(storage, as: Wrapped.self)
    return Wrapped.streamContainerFrame(at: storage)
  }
}
