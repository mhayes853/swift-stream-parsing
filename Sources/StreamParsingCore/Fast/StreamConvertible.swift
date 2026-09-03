// MARK: - Protocols

// Anything a container can hold, since an element has to exist before it can be written into.
public protocol StreamInitializable: SendableMetatype {
  static func streamInitialValue() -> Self
}

public protocol StreamStringConvertible: StreamInitializable {
  // Returns whether the bytes were taken. Unbounded storage answers `.applied` unconditionally
  // and the result folds away on specialization; bounded storage is the reason the result exists,
  // and answers `.capacityExceeded` without taking any of the bytes, so a value holds exactly
  // what it accumulated up to the last append that fit.
  @discardableResult
  mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult

  // How a schema recognizes fixed-capacity inline storage without being able to name it.
  //
  // `_streamStringSchema` is generic over the destination and cannot spell
  // `StreamInlineString<capacity>` for a capacity it does not know, and an existential metatype
  // cast to ask the question would not survive into Embedded Swift. A static requirement with a
  // default answers it instead: it is read once when a schema is built, never per token, and
  // specializes to a constant that folds the branch away for every type that leaves it zero.
  //
  // Zero means "not inline storage". A non-zero value is a promise about layout, checked in
  // `_streamStringSchema`: `_streamInlineByteOffset` bytes of header, then exactly that many
  // bytes of UTF-8 storage, which is what lets `PartialSink` append to it without naming it.
  static var _streamInlineCapacity: Int { get }
  static var _streamInlineByteOffset: Int { get }
}

extension StreamStringConvertible {
  @inlinable
  public static var _streamInlineCapacity: Int { 0 }
  @inlinable
  public static var _streamInlineByteOffset: Int { 0 }
}

public protocol StreamNumberConvertible: SendableMetatype {
  init?(streamParsing bytes: Span<UInt8>, info: NumberInfo)
}

public protocol StreamBooleanConvertible: SendableMetatype {
  init(streamParsingBoolean value: Bool)
}

public protocol StreamNullable: SendableMetatype {
  static func streamNullValue() -> Self
}

// MARK: - Integers

extension FixedWidthInteger {
  // A token carrying an exponent is rejected rather than scaled, matching prior behaviour.
  // Inlinable so a generic caller specialised for a concrete integer gets a specialised
  // conversion: reached through the protocol witness alone this ran unspecialised, with a
  // metadata lookup per number, and the batch appender measured Mesh at half speed.
  @inlinable
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard !info.flags.contains(.fraction), info.exponent == 0 else { return nil }

    // The accumulator flags anything it could not hold in a UInt64, which includes values that
    // do fit the destination: UInt64.max is twenty digits. Walking the token settles it rather
    // than rejecting a number the type can represent.
    if info.flags.contains(.overflowed) {
      guard let rescanned = _streamRescanInteger(bytes, as: Self.self) else { return nil }
      self = rescanned
      return
    }

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
  // For types narrower than Double, `Self(exactly: scale)` narrows the usable exponent window to
  // the powers that type can itself represent exactly; the arithmetic still rounds only once.
  @inlinable
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard !info.flags.contains(.overflowed) else {
      guard let fallback = streamParseFloatingPointFallback(bytes, as: Self.self) else {
        return nil
      }
      self = fallback
      return
    }

    if let significand = Self(exactly: info.magnitude) {
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
    }

    // Everything the two exact paths above could not reach, which is where `canada.json` sent
    // 91.2% of its tokens: a significand past the mantissa, or a power of ten beyond 10^22.
    // 10^22 is the last power whose factor of five fits Double's 53-bit significand; using the
    // rounded Double value of 10^23 or above as a scale can miss the correctly rounded result by
    // one ULP. Eisel-Lemire answers values inside its table bit-exactly and declines rather than
    // guessing, leaving the existing fallback to handle exponents outside that table.
    //
    // `Double`'s alone, deliberately. The kernel computes in `Double`, so a narrower `Self` would
    // round twice -- once into `Double`, once into `Self` -- which is *worse* than the fallback
    // those cases take today, and a wider one would lose bits outright. The metatype comparison
    // folds away when the generic specialises, so `Double` pays nothing for the check and the
    // other types keep exactly the behaviour they had.
    if Self.self == Double.self,
      let value = streamEiselLemire(
        magnitude: info.magnitude,
        exponent: Int(info.exponent),
        negative: info.flags.contains(.negative)
      ),
      let typed = Self(exactly: value)
    {
      self = typed
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
  // JSON has no infinity, and a token that scales past the type's range is out of range rather
  // than infinite, which is what the registration based parser reported too.
  guard let parsed = T(text), parsed.isFinite else { return nil }
  return parsed
}

// The standard library's own conformances live in Support/StandardLibrary.swift, next to the
// registration based ones they replace, so removing the old parser is a single subtraction.

// Walks the digits of an integer token. Reached only when the accumulated magnitude cannot be
// trusted, so it is off the hot path. No String, so it stays inside the embedded subset.
@usableFromInline
func _streamRescanInteger<T: FixedWidthInteger>(_ bytes: Span<UInt8>, as type: T.Type) -> T? {
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
