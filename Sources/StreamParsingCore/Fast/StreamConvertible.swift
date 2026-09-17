// MARK: - Protocols

// Anything a container can hold, since an element has to exist before it can be written into.
public protocol StreamInitializable: SendableMetatype {
  static func streamInitialValue() -> Self
}

public protocol StreamStringConvertible: StreamInitializable {
  // Whether the bytes were taken. Unbounded storage answers `.applied` (folded on specialization);
  // bounded storage answers `.capacityExceeded` without taking any bytes, so a value holds exactly
  // what it accumulated up to the last append that fit.
  @discardableResult
  mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult

  // How a schema recognizes inline storage it cannot name: a static requirement, not a metatype
  // cast (`_streamStringSchema` cannot spell `StreamInlineString<capacity>`, and an existential
  // cast would not survive Embedded). Zero means not inline; non-zero promises (checked in
  // `_streamStringSchema`) `_streamInlineByteOffset` header bytes, then that many UTF-8 bytes.
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
  // A token carrying an exponent is rejected rather than scaled. Inlinable so a specialised caller
  // gets a specialised conversion: through the protocol witness alone it paid a metadata lookup
  // per number, Mesh at half speed.
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
      // Integer-to-integer `init?(exactly:)` folds to a range compare, so the objection the
      // floating-point path below raises against `init(exactly:)` does not apply here. The bound is
      // in `Self.Magnitude`, not `UInt64`: widening the other way traps past 64 bits.
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
  // Accumulation, not a string round trip, in three generic tiers: Clinger's exact path (bounds
  // fold per `Self`, 2^53 / 10^22 for `Double`), Eisel-Lemire on `Self`'s format (91.2% of canada),
  // then the standard library for declines and wrapped 20+ digit magnitudes. No `init(exactly:)`:
  // each lowered to redundant work (NEW_ARCHITECTURE.md, "Three `init(exactly:)` calls").
  @inlinable
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    // Raw-bit tests, so the pair is a `tbnz` on a held register rather than two `OptionSet` calls;
    // the masks are the flags' computed `@inlinable` statics, which fold to immediates.
    let flags = info.flags.rawValue
    guard flags & NumberInfo.Flags.overflowed.rawValue == 0 else {
      // More than nineteen digits: `magnitude` has wrapped, so nothing below may look at it.
      guard let fallback = streamParseFloatingPointFallback(bytes, as: Self.self) else {
        return nil
      }
      self = fallback
      return
    }

    let magnitude = info.magnitude
    let exponent = Int(info.exponent)
    let negative = flags & NumberInfo.Flags.negative.rawValue != 0

    if magnitude <= streamMaxExactMagnitude(Self.self) {
      let unsigned = Self(magnitude)
      let significand = negative ? -unsigned : unsigned
      if exponent == 0 {
        self = significand
        return
      }
      let index = exponent < 0 ? -exponent : exponent
      if index <= streamMaxExactPow10(Self.self) {
        let scale = Self(streamExactPow10(index))
        // Split rather than written as one `?:` so a corpus whose exponents all have one sign
        // pays a predicted branch instead of an unconditional `fdiv` it throws away.
        if exponent >= 0 {
          self = significand * scale
          return
        }
        self = significand / scale
        return
      }
    }

    if let value = streamEiselLemireAny(
      magnitude: magnitude,
      exponent: exponent,
      negative: negative,
      as: Self.self
    ) {
      self = value
      return
    }

    guard let fallback = streamParseFloatingPointFallback(bytes, as: Self.self) else {
      return nil
    }
    self = fallback
  }
}

// Eisel-Lemire for the formats with a `StreamBinaryFormat`, a decline for any other type. The
// extension above cannot require the conformance, so a type test asks (folded on specialisation).
// `Float` is *not* narrowed from `Double`: decimal -> `Double` -> `Float` rounds twice and is not
// correctly rounded in general (`7.038531e-26`).
@inlinable
@inline(__always)
func streamEiselLemireAny<T: BinaryFloatingPoint>(
  magnitude: UInt64, exponent: Int, negative: Bool, as type: T.Type
) -> T? {
  // The type test guards the `unsafeBitCast`, a no-op on the only branch reaching it. Measured:
  // with `.map` the unspecialised generic formed a real closure (a metadata instantiation and three
  // partial-apply forwarders); keep the `guard`.
  @inline(__always)
  func bridge<F: StreamBinaryFormat>(_ format: F.Type) -> T? {
    guard
      let value = streamEiselLemire(
        magnitude: magnitude, exponent: exponent, negative: negative, as: F.self
      )
    else { return nil }
    return unsafeBitCast(value, to: T.self)
  }
  if T.self == Double.self { return bridge(Double.self) }
  if T.self == Float.self { return bridge(Float.self) }
  return nil
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
