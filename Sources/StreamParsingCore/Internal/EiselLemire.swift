import StreamParsingShims

// Eisel-Lemire: decimal significand and power of ten to the correctly rounded binary float, with
// a second 64x64 multiply only when the first cannot decide. Takes what the Clinger exact path
// cannot. Declines (`nil`) rather than guesses in two cases, an all-ones low word and an
// unseparable halfway value (~0.2% of random input, left to the `String` fallback). Generic over
// the binary format (fast_float's `binary_format<T>`), so `Float` is correctly rounded, not
// narrowed from `Double`; the shared 128-bit table spans 10^-342 ... 10^308.

@inlinable
package var streamPow10MinExponent: Int { Int(STREAM_PARSING_POW10_128_MIN_EXPONENT) }

@inlinable
package var streamPow10MaxExponent: Int { Int(STREAM_PARSING_POW10_128_MAX_EXPONENT) }

// MARK: - Binary format

// The destination's constants. Three derive from `significandBitCount`/`exponentBitCount` via the
// defaults below; the round-to-even window and subnormal cutoff are stated per format, as in
// fast_float. All fold to immediates: `streamEiselLemire<Double>` must stay instruction for
// instruction the hand-written `Double` kernel.
@usableFromInline
protocol StreamBinaryFormat: BinaryFloatingPoint {
  // The raw bit pattern of the format: `UInt64` for `Double`, `UInt32` for `Float`.
  associatedtype StreamBits: FixedWidthInteger & UnsignedInteger

  // Explicit (stored) mantissa bits: 52 / 23. The implicit leading one is not counted.
  static var streamMantissaBits: Int { get }
  // The exponent of the smallest normal, i.e. `-bias`: -1023 / -127.
  static var streamMinExponent: Int { get }
  // The all-ones biased exponent: 0x7FF / 0xFF. A computed power at or above it overflows.
  static var streamInfinitePower: Int { get }
  // The decimal exponent window where an exact halfway value is possible and the (mantissa + 3)-bit
  // approximation cannot separate the rounding: fast_float's `min/max_exponent_round_to_even`.
  static var streamMinRoundToEven: Int { get }
  static var streamMaxRoundToEven: Int { get }
  // The largest decimal exponent at which a subnormal result is possible: the arm needs
  // `floor(q * log2(10)) <= streamMinExponent` (worst case 63 leading zeros), so q <= -308 for
  // `Double` and q <= -38 for `Float`. Above it the ordinary path skips that arm entirely.
  static var streamSubnormalCutoff: Int { get }

  static func streamFromBits(_ bits: StreamBits) -> Self
}

extension StreamBinaryFormat {
  // The bias is `2^(exponentBitCount - 1) - 1`, so the smallest normal's exponent is its negation
  // and the all-ones biased exponent is `2^exponentBitCount - 1`.
  @inlinable static var streamMantissaBits: Int { Self.significandBitCount }
  @inlinable static var streamMinExponent: Int { -((1 << (Self.exponentBitCount &- 1)) &- 1) }
  @inlinable static var streamInfinitePower: Int { (1 << Self.exponentBitCount) &- 1 }
}

extension Double: StreamBinaryFormat {
  @inlinable static var streamMinRoundToEven: Int { -4 }
  @inlinable static var streamMaxRoundToEven: Int { 23 }
  @inlinable static var streamSubnormalCutoff: Int { -308 }
  @inlinable
  static func streamFromBits(_ bits: UInt64) -> Double { Double(bitPattern: bits) }
}

extension Float: StreamBinaryFormat {
  @inlinable static var streamMinRoundToEven: Int { -17 }
  @inlinable static var streamMaxRoundToEven: Int { 10 }
  @inlinable static var streamSubnormalCutoff: Int { -38 }
  @inlinable
  static func streamFromBits(_ bits: UInt32) -> Float { Float(bitPattern: bits) }
}

// MARK: - Kernel

// The top 128 bits of 10^q, the second multiply only when the first cannot decide. The mask keeps
// the `64 - (mantissa + 3)` unused bits (implicit bit, rounding bit, `upperBit` shift): 0x1FF for
// `Double`, 0x3F_FFFF_FFFF for `Float`, which reaches the second multiply more often, correctly.
@inlinable
@inline(__always)
package func streamPow10Product(
  _ exponent: Int, _ significand: UInt64, precisionMask: UInt64
) -> (high: UInt64, low: UInt64) {
  let index = 2 &* (exponent &- streamPow10MinExponent)
  // Always a static `.rodata` address: the unsafe unwrap keeps a null check out of the kernel.
  let table = stream_parsing_pow10_128().unsafelyUnwrapped
  let (firstHigh, firstLow) = significand.multipliedFullWidth(by: table[index])
  guard firstHigh & precisionMask == precisionMask else { return (firstHigh, firstLow) }
  let (secondHigh, _) = significand.multipliedFullWidth(by: table[index &+ 1])
  let (low, carried) = firstLow.addingReportingOverflow(secondHigh)
  return (carried ? firstHigh &+ 1 : firstHigh, low)
}

// `((152170 + 65536) * q) >> 16` is floor(q * log2(10)) over the table's range; 63 accounts for
// the normalisation shift. Independent of the destination format.
@inlinable
@inline(__always)
package func streamPowerOfTwoExponent(_ exponent: Int) -> Int {
  ((152_170 &+ 65_536) &* exponent) >> 16 &+ 63
}

@inlinable
func streamEiselLemire<T: StreamBinaryFormat>(
  magnitude: UInt64, exponent: Int, negative: Bool, as type: T.Type
) -> T? {
  // Every one of these folds to an immediate once `T` is known.
  let mantissaBits = T.streamMantissaBits
  let signBit: T.StreamBits = negative ? (1 << (T.StreamBits.bitWidth &- 1)) : 0

  if magnitude == 0 || exponent < streamPow10MinExponent {
    // Only a zero significand is zero here; a nonzero value below the table floor declines, like
    // one above the ceiling.
    return magnitude == 0 ? T.streamFromBits(signBit) : nil
  }
  guard exponent <= streamPow10MaxExponent else { return nil }

  let leadingZeros = magnitude.leadingZeroBitCount
  let normalized = magnitude << UInt64(leadingZeros)
  let product = streamPow10Product(
    exponent,
    normalized,
    precisionMask: UInt64.max >> UInt64(mantissaBits &+ 3)
  )
  guard product.low != UInt64.max else { return nil }

  let upperBit = Int(product.high >> 63)
  // `mantissa + 3` significant bits, from the top of the product.
  var mantissa = product.high >> UInt64(upperBit &+ (64 &- mantissaBits &- 3))

  // Unreachable above the cutoff (even `1e-307` is normal), and guarding it keeps the power
  // calculation off ordinary exponents' dependency chain. Measured: recovered half of Canada's 2%
  // full-table regression; out of line was worse. See NEW_ARCHITECTURE.md.
  if exponent <= T.streamSubnormalCutoff {
    let subnormalPower2 =
      streamPowerOfTwoExponent(exponent) &+ upperBit &- leadingZeros &- T.streamMinExponent
    if subnormalPower2 <= 0 {
      // Subnormal, or rounds to zero: the mantissa takes the shift the exponent cannot express.
      guard -subnormalPower2 &+ 1 < 64 else { return T.streamFromBits(signBit) }
      mantissa >>= UInt64(-subnormalPower2 &+ 1)
      mantissa &+= mantissa & 1
      mantissa >>= 1
      // Rounding up out of the subnormal range lands on the smallest normal (biased exponent one),
      // and the carried value already has exactly the right low bits.
      let biased: UInt64 = mantissa < (1 << UInt64(mantissaBits)) ? 0 : 1
      return T.streamFromBits(
        signBit
          | T.StreamBits(truncatingIfNeeded: (biased << UInt64(mantissaBits)) | mantissa)
      )
    }
  }

  // The one case the approximation cannot separate: an exact halfway value where only the product's
  // low word distinguishes round-up from round-down.
  if product.low <= 1, exponent >= T.streamMinRoundToEven, exponent <= T.streamMaxRoundToEven,
    mantissa & 3 == 1
  { return nil }

  mantissa &+= mantissa & 1
  mantissa >>= 1
  var power2 =
    streamPowerOfTwoExponent(exponent) &+ upperBit &- leadingZeros &- T.streamMinExponent
  if mantissa >= (1 << UInt64(mantissaBits &+ 1)) {
    mantissa >>= 1
    power2 &+= 1
  }
  guard power2 < T.streamInfinitePower else { return nil }
  mantissa &= ~(1 << UInt64(mantissaBits))
  return T.streamFromBits(
    // `power2` is proven positive; truncating avoids a sign check leading to an unreachable trap.
    signBit
      | T.StreamBits(
        truncatingIfNeeded: (UInt64(truncatingIfNeeded: power2) << UInt64(mantissaBits)) | mantissa
      )
  )
}
