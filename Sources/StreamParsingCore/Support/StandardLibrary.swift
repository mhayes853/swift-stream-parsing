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

extension Array: StreamParseableRoot where Element: StreamParseableRoot {
  public static var streamSchema: StreamSchema {
    _streamArraySchema(Element.self, element: Element.streamSchema)
  }

  // reserveCapacity plus append forces a fresh buffer. Sharing one is the whole problem: the sink
  // writes elements through a raw pointer, so nothing uniquifies on its behalf. The recursion is
  // required rather than tidy, because an inner element is written through a raw pointer too.
  public func streamSnapshot() -> Self {
    var copy = [Element]()
    copy.reserveCapacity(self.count)
    for element in self { copy.append(element.streamSnapshot()) }
    return copy
  }
}

extension StreamDictionary: StreamParseableRoot where Value: StreamParseableRoot {
  public static var streamSchema: StreamSchema {
    _streamDictionarySchema(Value.self, value: Value.streamSchema)
  }

  public func streamSnapshot() -> Self {
    var copy = Self()
    copy.storedKeys.reserveCapacity(self.storedKeys.count)
    copy.storedValues.reserveCapacity(self.storedValues.count)
    for slot in self.storedValues.indices {
      copy.append(self.storedValues[slot].streamSnapshot(), forKey: self.storedKeys[slot])
    }
    return copy
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
  public typealias Partial = [Element.Partial]

  public var streamPartialValue: [Element.Partial] {
    self.map(\.streamPartialValue)
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
  public func streamSnapshot() -> Self {
    self?.streamSnapshot()
  }

  public static var streamSchema: StreamSchema {
    StreamSchema(
      shape: Wrapped.streamSchema.shape,
      matchField: { key in Wrapped.streamSchema.matchField(key) },
      applyString: { storage, field, bytes in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return Wrapped.streamSchema.applyString(storage, field, bytes)
      },
      applyNumber: { storage, field, bytes, info in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return Wrapped.streamSchema.applyNumber(storage, field, bytes, info)
      },
      applyBoolean: { storage, field, value in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return Wrapped.streamSchema.applyBoolean(storage, field, value)
      },
      applyNull: { storage, _ in
        storage.assumingMemoryBound(to: Wrapped?.self).pointee = nil
        return true
      },
      enterField: { storage, field in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return Wrapped.streamSchema.enterField(storage, field)
      },
      appendElement: { storage in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return Wrapped.streamSchema.appendElement(storage)
      },
      enterKey: { storage, key in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return Wrapped.streamSchema.enterKey(storage, key)
      }
    )
  }
}
