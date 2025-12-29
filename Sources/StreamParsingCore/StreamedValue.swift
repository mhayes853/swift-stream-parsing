@nonexhaustive
public enum StreamedValue: Hashable, Sendable {
  case string(String)
  case double(Double)
  case float(Float)
  case boolean(Bool)
  case null

  case int8(Int8)
  case int16(Int16)
  case int32(Int32)
  case int64(Int64)
  case int128(high: Int64, low: UInt64)
  case int(Int)

  case uint8(UInt8)
  case uint16(UInt16)
  case uint32(UInt32)
  case uint64(UInt64)
  case uint128(high: UInt64, low: UInt64)
  case uint(UInt)

  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  public static func int128(_ value: Int128) -> Self {
    .int128(high: value._high, low: value._low)
  }

  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  public static func uint128(_ value: UInt128) -> Self {
    .uint128(high: value._high, low: value._low)
  }
}

extension StreamedValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self = .string(value)
  }
}

extension StreamedValue: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: Int) {
    self = .int(value)
  }
}

extension StreamedValue: ExpressibleByFloatLiteral {
  public init(floatLiteral value: Double) {
    self = .double(value)
  }
}

extension StreamedValue: ExpressibleByBooleanLiteral {
  public init(booleanLiteral value: Bool) {
    self = .boolean(value)
  }
}

extension StreamedValue: ExpressibleByNilLiteral {
  public init(nilLiteral: ()) {
    self = .null
  }
}
