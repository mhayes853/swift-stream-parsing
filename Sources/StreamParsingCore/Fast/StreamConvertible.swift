// MARK: - Protocols

// Anything a container can hold, since an element has to exist before it can be written into.
public protocol StreamInitializable {
  static func streamInitialValue() -> Self
}

public protocol StreamStringConvertible: StreamInitializable {
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
      guard Self.isSigned else { return nil }
      // The bound is expressed in Self.Magnitude rather than UInt64, because widening the
      // other way traps for types wider than 64 bits.
      guard let magnitude = Self.Magnitude(exactly: info.magnitude),
        magnitude <= Self.min.magnitude
      else { return nil }
      if magnitude == Self.min.magnitude {
        self = Self.min
        return
      }
      self = 0 &- Self(magnitude)
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

// The standard library's own conformances live in Support/StandardLibrary.swift, next to the
// registration based ones they replace, so removing the old parser is a single subtraction.
