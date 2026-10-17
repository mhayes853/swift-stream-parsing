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

// BinaryFloatingPoint describes the logical encoding, including Float80's implicit
// leading bit at this API boundary. None of these require a packed storage word.
// On specialization the format constants and RawExponent/RawSignificand conversions
// must fold away; the Double/Float kernels should remain scalar integer arithmetic.
extension BinaryFloatingPoint {
  // Negative bias, not the exponent of the smallest normal (which is 1 - bias).
  @inlinable static var streamMinExponent: Int { -((1 << (Self.exponentBitCount &- 1)) &- 1) }
  @inlinable static var streamInfinitePower: Int { (1 << Self.exponentBitCount) &- 1 }

  // Keep fast_float's tight windows for the existing 53/24-bit paths. Other
  // precisions conservatively decline every potentially ambiguous halfway value.
  // This changes coverage, never rounding, and keeps implementation knobs internal.
  @inlinable static var streamMinRoundToEven: Int {
    switch Self.significandBitCount {
    case 52: -4
    case 23: -17
    default: streamPow10MinExponent
    }
  }
  @inlinable static var streamMaxRoundToEven: Int {
    switch Self.significandBitCount {
    case 52: 23
    case 23: 10
    default: streamPow10MaxExponent
    }
  }

  // floor((1 - bias) * log10(2)): -308 / -38 / -5 for Double/Float/Float16.
  // If the bias exceeds the table's binary range, this cutoff is below every row.
  @inlinable static var streamSubnormalCutoff: Int {
    ((Self.streamMinExponent &+ 1) &* 19_728) >> 16
  }
}

@inlinable
@inline(__always)
func streamFloatFromParts<T: BinaryFloatingPoint>(
  negative: Bool, power: Int, mantissa: UInt64, as type: T.Type
) -> T {
  T(
    sign: negative ? .minus : .plus,
    exponentBitPattern: T.RawExponent(truncatingIfNeeded: power),
    significandBitPattern: T.RawSignificand(truncatingIfNeeded: mantissa)
  )
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
func streamEiselLemire<T: BinaryFloatingPoint>(
  magnitude: UInt64, exponent: Int, negative: Bool, as type: T.Type
) -> T? {
  // Every one of these folds to an immediate once `T` is known.
  let mantissaBits = T.significandBitCount
  if magnitude == 0 { return negative ? -T.zero : T.zero }
  guard exponent >= streamPow10MinExponent, exponent <= streamPow10MaxExponent,
    mantissaBits >= 1, mantissaBits <= 63,
    T.exponentBitCount >= 2, T.exponentBitCount < Int.bitWidth - 16
  else { return nil }

  // The narrow kernel needs mantissa + 3 bits in one word. The 63/64-bit
  // precision path retains all three words of the product instead.
  if mantissaBits >= 62 {
    return streamEiselLemireWide(
      magnitude: magnitude, exponent: exponent, negative: negative, as: T.self
    )
  }

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
      guard -subnormalPower2 &+ 1 < 64 else { return negative ? -T.zero : T.zero }
      mantissa >>= UInt64(-subnormalPower2 &+ 1)
      mantissa &+= mantissa & 1
      mantissa >>= 1
      // Rounding up out of the subnormal range lands on the smallest normal (biased exponent one),
      // and the carried value already has exactly the right low bits.
      let biased = mantissa < (1 << UInt64(mantissaBits)) ? 0 : 1
      return streamFloatFromParts(
        negative: negative, power: biased,
        mantissa: mantissa & ((1 << UInt64(mantissaBits)) &- 1), as: T.self
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
  return streamFloatFromParts(
    negative: negative, power: power2, mantissa: mantissa, as: T.self
  )
}

// MARK: - 63/64-bit precision

// Exact 64 x 128 -> 192-bit multiplication of the normalized significand and
// truncated table row. The narrow path omits the bottom word and usually the
// second multiply; Float80 needs them to separate rounding at 64-bit precision.
@inlinable
@inline(__always)
package func streamPow10WideProduct(
  _ exponent: Int, _ significand: UInt64
) -> (high: UInt64, middle: UInt64, low: UInt64) {
  let index = 2 &* (exponent &- streamPow10MinExponent)
  let table = stream_parsing_pow10_128().unsafelyUnwrapped
  let (firstHigh, firstLow) = significand.multipliedFullWidth(by: table[index])
  let (secondHigh, secondLow) = significand.multipliedFullWidth(by: table[index &+ 1])
  let (middle, carried) = firstLow.addingReportingOverflow(secondHigh)
  return (carried ? firstHigh &+ 1 : firstHigh, middle, secondLow)
}

// Round a 192-bit integer after a shift of 127, 128, or 129: the precision window
// for normal values with 63/64-bit precision. Keep a carry separately so rounding
// to 2^64 can advance the exponent.
@inlinable
@inline(__always)
func streamRoundWideProduct(
  high: UInt64, middle: UInt64, low: UInt64, shift: Int
) -> (mantissa: UInt64, carried: Bool) {
  let mantissa: UInt64
  let roundBit: UInt64
  let sticky: Bool
  if shift == 127 {
    mantissa = (high << 1) | (middle >> 63)
    roundBit = (middle >> 62) & 1
    sticky = middle & ((1 << 62) &- 1) != 0 || low != 0
  } else if shift == 128 {
    mantissa = high
    roundBit = middle >> 63
    sticky = middle & (UInt64.max >> 1) != 0 || low != 0
  } else {
    mantissa = high >> 1
    roundBit = high & 1
    sticky = middle != 0 || low != 0
  }
  let rounded = mantissa.addingReportingOverflow(roundBit & ((sticky ? 1 : 0) | (mantissa & 1)))
  return (rounded.partialValue, rounded.overflow)
}

@inlinable
func streamEiselLemireWide<T: BinaryFloatingPoint>(
  magnitude: UInt64, exponent: Int, negative: Bool, as type: T.Type
) -> T? {
  let mantissaBits = T.significandBitCount
  let leadingZeros = magnitude.leadingZeroBitCount
  let normalized = magnitude << leadingZeros
  let product = streamPow10WideProduct(exponent, normalized)
  let upperBit = Int(product.high >> 63)
  var power2 =
    streamPowerOfTwoExponent(exponent) &+ upperBit &- leadingZeros &- T.streamMinExponent
  // Every Float80 result in the shared table is normal. Other wide formats
  // use the complete-token fallback for subnormals instead of extending the
  // three rounding shifts above to cover their entire exponent range.
  guard power2 > 0 else { return nil }
  let shift = 190 &+ upperBit &- mantissaBits
  let rounded = streamRoundWideProduct(
    high: product.high, middle: product.middle, low: product.low, shift: shift
  )

  // A normalized row C bounds the true power by C <= power < C + 1,
  // hence P <= normalized * power < P + normalized. Accept only if BOTH
  // endpoints round to the same result rather than guessing at table truncation.
  // Rows 0...55 are exact (5^55 fits in 128 bits), so exact ties can round even.
  if exponent < 0 || exponent > 55 {
    let (upperLow, lowCarry) = product.low.addingReportingOverflow(normalized)
    let (upperMiddle, middleCarry) = product.middle.addingReportingOverflow(lowCarry ? 1 : 0)
    let (upperHigh, highCarry) = product.high.addingReportingOverflow(middleCarry ? 1 : 0)
    guard !highCarry else { return nil }
    let upperRounded = streamRoundWideProduct(
      high: upperHigh, middle: upperMiddle, low: upperLow, shift: shift
    )
    guard rounded == upperRounded else { return nil }
  }

  var mantissa = rounded.mantissa
  let implicitBit: UInt64 = 1 << mantissaBits
  if rounded.carried {
    mantissa = implicitBit
    power2 &+= 1
  } else if mantissaBits < 63, mantissa >= (implicitBit << 1) {
    mantissa >>= 1
    power2 &+= 1
  }
  guard power2 < T.streamInfinitePower else { return nil }
  return streamFloatFromParts(
    negative: negative, power: power2, mantissa: mantissa & (implicitBit &- 1), as: T.self
  )
}
