// MARK: - Protocols

public protocol StreamStringConvertible {
  static func streamInitialValue() -> Self
  mutating func streamAppend(utf8 bytes: Span<UInt8>)
  mutating func streamReserve(utf8ByteCount: Int)
}

extension StreamStringConvertible {
  public mutating func streamReserve(utf8ByteCount: Int) {}
}

public protocol StreamNumberConvertible {
  init?(streamParsing bytes: Span<UInt8>, info: NumberInfo)
}

public protocol StreamBooleanConvertible {
  init(streamParsingBoolean value: Bool)
}

public protocol StreamNullable {
  static func streamNullValue() -> Self
}

// MARK: - Integers

extension FixedWidthInteger {
  // A token carrying an exponent is rejected rather than scaled, matching prior behaviour.
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard info.isExactInteger, !info.flags.contains(.fraction) else { return nil }

    if info.flags.contains(.negative) {
      guard Self.isSigned, info.magnitude <= UInt64(Self.max.magnitude) &+ 1 else { return nil }
      if info.magnitude == UInt64(Self.max.magnitude) &+ 1 {
        self = Self.min
        return
      }
      guard let positive = Self(exactly: info.magnitude) else { return nil }
      self = 0 &- positive
      return
    }

    guard let value = Self(exactly: info.magnitude) else { return nil }
    self = value
  }
}

// MARK: - Floating point

extension BinaryFloatingPoint where Self: LosslessStringConvertible {
  // Accumulation rather than a string round trip. Both operands of the scale are exact when the
  // significand fits the mantissa and the power of ten is in the exactly representable range,
  // so a single rounding gives the correctly rounded result. Multiplication is used for a
  // positive exponent and division for a negative one, because a negative power of ten is not
  // itself exact.
  //
  // Anything outside that range falls back to the standard library's parser, which is slow but
  // correct.
  //
  // Known gap: for types narrower than Double the scaled path rounds twice, once into Double
  // and once into Self, which can differ from the correctly rounded result in rare cases. Float
  // needs its own bound before this is relied on for exactness.
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard !info.flags.contains(.overflowed) else {
      guard let fallback = streamParseFloatingPointFallback(bytes, as: Self.self) else {
        return nil
      }
      self = fallback
      return
    }

    guard let significand = Self(exactly: info.magnitude) else {
      guard let fallback = streamParseFloatingPointFallback(bytes, as: Self.self) else {
        return nil
      }
      self = fallback
      return
    }

    if info.exponent == 0 {
      self = info.flags.contains(.negative) ? -significand : significand
      return
    }

    let exponent = Int(info.exponent)
    if info.magnitude <= (1 << 53),
      let scale = digitPow10Value(abs(exponent)),
      let typedScale = Self(exactly: scale)
    {
      let scaled = exponent >= 0 ? significand * typedScale : significand / typedScale
      self = info.flags.contains(.negative) ? -scaled : scaled
      return
    }

    guard let fallback = streamParseFloatingPointFallback(bytes, as: Self.self) else {
      return nil
    }
    self = fallback
  }
}

@usableFromInline
func streamParseFloatingPointFallback<T: BinaryFloatingPoint & LosslessStringConvertible>(
  _ bytes: Span<UInt8>, as type: T.Type
) -> T? {
  // Numeric tokens are ASCII, so a scalar-wise build is exact.
  var text = ""
  text.reserveCapacity(bytes.count)
  for i in 0..<bytes.count {
    text.unicodeScalars.append(Unicode.Scalar(bytes[i]))
  }
  return T(text)
}

// MARK: - Standard library conformances

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

extension Bool: StreamBooleanConvertible {
  public init(streamParsingBoolean value: Bool) { self = value }
}

extension Optional: StreamNullable {
  public static func streamNullValue() -> Self { nil }
}

extension Int: StreamNumberConvertible {}
extension Int8: StreamNumberConvertible {}
extension Int16: StreamNumberConvertible {}
extension Int32: StreamNumberConvertible {}
extension Int64: StreamNumberConvertible {}
extension UInt: StreamNumberConvertible {}
extension UInt8: StreamNumberConvertible {}
extension UInt16: StreamNumberConvertible {}
extension UInt32: StreamNumberConvertible {}
extension UInt64: StreamNumberConvertible {}
extension Double: StreamNumberConvertible {}
extension Float: StreamNumberConvertible {}
