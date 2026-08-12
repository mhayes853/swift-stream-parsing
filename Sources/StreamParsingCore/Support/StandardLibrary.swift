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

// The accumulator carries magnitude in a UInt64, so a value wider than that arrives flagged as
// overflowed with nothing usable in it. The registration based parser scanned the token for
// these two types, so taking the shared conversion unchanged would narrow their range to 64
// bits. They re-scan instead, which only happens for tokens that actually need it.

@available(StreamParsing128BitIntegers, *)
extension Int128: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }

  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = streamParseWideInteger(bytes, info: info, as: Self.self) else { return nil }
    self = value
  }
}

@available(StreamParsing128BitIntegers, *)
extension UInt128: StreamNumberConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { 0 }

  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = streamParseWideInteger(bytes, info: info, as: Self.self) else { return nil }
    self = value
  }
}

// Takes the accumulated magnitude when it is trustworthy and walks the digits when it is not.
// No String, so this stays inside the embedded subset.
@usableFromInline
func streamParseWideInteger<T: FixedWidthInteger>(
  _ bytes: Span<UInt8>, info: NumberInfo, as type: T.Type
) -> T? {
  guard !info.flags.contains(.fraction), info.exponent == 0 else { return nil }

  guard info.flags.contains(.overflowed) else {
    return T(streamParsing: bytes, info: info)
  }

  var index = 0
  var isNegative = false
  if index < bytes.count, bytes[index] == .asciiDash {
    guard T.isSigned else { return nil }
    isNegative = true
    index &+= 1
  }
  guard index < bytes.count else { return nil }

  var magnitude = T.Magnitude.zero
  while index < bytes.count {
    let byte = bytes[index]
    guard byte >= .asciiZero, byte <= .asciiNine else { return nil }
    let (multiplied, multiplyOverflowed) = magnitude.multipliedReportingOverflow(by: 10)
    guard !multiplyOverflowed else { return nil }
    let (added, addOverflowed) = multiplied.addingReportingOverflow(
      T.Magnitude(byte &- .asciiZero)
    )
    guard !addOverflowed else { return nil }
    magnitude = added
    index &+= 1
  }

  guard isNegative else { return T(exactly: magnitude) }
  guard magnitude <= T.min.magnitude else { return nil }
  return magnitude == T.min.magnitude ? T.min : 0 &- T(magnitude)
}

// MARK: - String

extension String: StreamParseable {
  public typealias Partial = Self
}

extension String: StreamParseableValue {
  public static func initialParseableValue() -> Self {
    ""
  }

  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerStringHandler(\.self)
  }
}

// MARK: - Double

extension Double: StreamParseable {
  public typealias Partial = Self
}

extension Double: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerDoubleHandler(\.self)
  }
}

// MARK: - Float

extension Float: StreamParseable {
  public typealias Partial = Self
}

extension Float: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerFloatHandler(\.self)
  }
}

// MARK: - Bool

extension Bool: StreamParseable {
  public typealias Partial = Self
}

extension Bool: StreamParseableValue {
  public static func initialParseableValue() -> Self {
    false
  }

  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerBoolHandler(\.self)
  }
}

// MARK: - Int8

extension Int8: StreamParseable {
  public typealias Partial = Self
}

extension Int8: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerInt8Handler(\.self)
  }
}

// MARK: - Int16

extension Int16: StreamParseable {
  public typealias Partial = Self
}

extension Int16: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerInt16Handler(\.self)
  }
}
// MARK: - Int32

extension Int32: StreamParseable {
  public typealias Partial = Self
}

extension Int32: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerInt32Handler(\.self)
  }
}

// MARK: - Int64

extension Int64: StreamParseable {
  public typealias Partial = Self
}

extension Int64: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerInt64Handler(\.self)
  }
}

// MARK: - Int

extension Int: StreamParseable {
  public typealias Partial = Self
}

extension Int: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerIntHandler(\.self)
  }
}

// MARK: - UInt8

extension UInt8: StreamParseable {
  public typealias Partial = Self
}

extension UInt8: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUInt8Handler(\.self)
  }
}

// MARK: - UInt16

extension UInt16: StreamParseable {
  public typealias Partial = Self
}

extension UInt16: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUInt16Handler(\.self)
  }
}

// MARK: - UInt32

extension UInt32: StreamParseable {
  public typealias Partial = Self
}

extension UInt32: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUInt32Handler(\.self)
  }
}

// MARK: - UInt64

extension UInt64: StreamParseable {
  public typealias Partial = Self
}

extension UInt64: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUInt64Handler(\.self)
  }
}

// MARK: - UInt

extension UInt: StreamParseable {
  public typealias Partial = Self
}

extension UInt: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUIntHandler(\.self)
  }
}

// MARK: - Int128

@available(StreamParsing128BitIntegers, *)
extension Int128: StreamParseable {
  public typealias Partial = Self
}

@available(StreamParsing128BitIntegers, *)
extension Int128: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerInt128Handler(\.self)
  }
}

// MARK: - UInt128

@available(StreamParsing128BitIntegers, *)
extension UInt128: StreamParseable {
  public typealias Partial = Self
}

@available(StreamParsing128BitIntegers, *)
extension UInt128: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUInt128Handler(\.self)
  }
}

// MARK: - Array

extension Array: StreamParseable where Element: StreamParseable {
  public typealias Partial = [Element.Partial]

  public var streamPartialValue: [Element.Partial] {
    self.map(\.streamPartialValue)
  }
}

extension Array: StreamParseableValue where Element: StreamParseableValue {
  public static func initialParseableValue() -> [Element] {
    []
  }
}

extension Array: StreamParseableArrayObject where Element: StreamParseableValue {}

// MARK: - Dictionary

extension Dictionary: StreamParseable where Key == String, Value: StreamParseable {
  public typealias Partial = [String: Value.Partial]

  public var streamPartialValue: [String: Value.Partial] {
    self.mapValues(\.streamPartialValue)
  }
}

extension Dictionary: StreamParseableValue where Key == String, Value: StreamParseableValue {
  public static func initialParseableValue() -> [String: Value] {
    [:]
  }
}

extension Dictionary: StreamParseableDictionaryObject
where Key == String, Value: StreamParseableValue {}

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

extension Optional: StreamParseableValue where Wrapped: StreamParseableValue {
  public static func initialParseableValue() -> Wrapped? {
    Wrapped.initialParseableValue()
  }

  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerScopedHandlers(on: Wrapped.self, \.streamParsingWrappedValue)
    handlers.registerNilHandler(\.self)
  }

  private var streamParsingWrappedValue: Wrapped {
    get { self ?? Wrapped.initialParseableValue() }
    set { self = newValue }
  }
}
