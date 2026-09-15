import StreamParsingShims

// Eisel-Lemire: a decimal significand and a power of ten to the correctly rounded binary float, one
// 64x64 multiply in the common case and a second only when the first product's low bits cannot
// decide the rounding. It takes everything the Clinger exact path cannot (NEW_ARCHITECTURE.md).
//
// **It declines rather than guesses**, at `nil`, in exactly two cases: a product whose low word is
// all ones, and a halfway case the (mantissa + 3)-bit approximation cannot separate — ~0.2% of
// random input, settled by the caller's `String` fallback. Every case it answers is bit-exact.
//
// Parameterised on the destination's binary format (fast_float's `binary_format<T>`), so `Float`
// gets a correctly rounded conversion rather than a double-rounding narrowing from `Double`. The
// 128-bit power of ten table is shared: it is a property of the decimal exponent, not the
// destination, and already spans -342 ... 308.

@inlinable
package var streamPow10MinExponent: Int { Int(STREAM_PARSING_POW10_128_MIN_EXPONENT) }

@inlinable
package var streamPow10MaxExponent: Int { Int(STREAM_PARSING_POW10_128_MAX_EXPONENT) }

// MARK: - Binary format

// Everything the kernel needs about the destination, as static constants. Three of the six derive
// from `significandBitCount`/`exponentBitCount` — hence the refinement, and the defaults below are
// the derivation, so a new format states only what cannot be derived. The round-to-even window and
// the subnormal cutoff are not derivable; fast_float hardcodes them per format too.
//
// Costs nothing at runtime: the kernel does integer arithmetic on the raw bit pattern only, and
// every constant folds to the immediate a hand-written `Double` kernel would use — which is the
// requirement, `streamEiselLemire<Double>` must stay instruction-for-instruction that kernel.
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
  // The decimal exponent window in which an exact halfway value is possible and the
  // (mantissa + 3)-bit approximation cannot separate round-up from round-down. fast_float's
  // `min/max_exponent_round_to_even`: -4 ... 23 for `Double`, -17 ... 10 for `Float`.
  static var streamMinRoundToEven: Int { get }
  static var streamMaxRoundToEven: Int { get }
  // The largest decimal exponent at or below which a subnormal result is possible; above it the
  // subnormal arm is unreachable for any significand, so the ordinary path skips computing the
  // binary exponent early. Derivation: the arm is reachable only when
  // `floor(q * log2(10)) <= streamMinExponent` (worst case 63 leading zeros, upper bit clear),
  // which is q <= -308 for `Double` and q <= -38 for `Float`.
  static var streamSubnormalCutoff: Int { get }

  static func streamFromBits(_ bits: StreamBits) -> Self
}

extension StreamBinaryFormat {
  // The three derivable ones. `significandBitCount` already excludes the implicit leading bit,
  // and the bias is `2^(exponentBitCount - 1) - 1`, so the smallest normal's exponent is its
  // negation and the all-ones biased exponent is `2^exponentBitCount - 1`. All static properties
  // of the type, so each folds to its immediate in a specialisation.
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

// The top 128 bits of 10^q, and a second multiply only when the first cannot decide. The
// precision mask keeps the bits the format does not use: `64 - (mantissa + 3)` of them, where the
// three extra are the implicit bit, the rounding bit, and the one the `upperBit` shift can cost.
// That is 0x1FF for `Double` and 0x3F_FFFF_FFFF for `Float` -- a wider mask, so `Float` reaches
// the second multiply more often, which is correct: it has fewer bits to spend on deciding.
@inlinable
@inline(__always)
package func streamPow10Product(
  _ exponent: Int, _ significand: UInt64, precisionMask: UInt64
) -> (high: UInt64, low: UInt64) {
  let index = 2 &* (exponent &- streamPow10MinExponent)
  // The C accessor always returns the address of static `.rodata`; unsafe unwrapping tells Swift
  // what C's type system cannot express and keeps a null check out of this inlined kernel.
  let table = stream_parsing_pow10_128().unsafelyUnwrapped
  let (firstHigh, firstLow) = significand.multipliedFullWidth(by: table[index])
  guard firstHigh & precisionMask == precisionMask else { return (firstHigh, firstLow) }
  let (secondHigh, _) = significand.multipliedFullWidth(by: table[index &+ 1])
  let (low, carried) = firstLow.addingReportingOverflow(secondHigh)
  return (carried ? firstHigh &+ 1 : firstHigh, low)
}

// `((152170 + 65536) * q) >> 16` is floor(q * log2(10)) over the table's exponent range, and 63
// accounts for the normalisation shift below. Independent of the destination format.
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
    // Only a true zero significand is a zero here. A nonzero value below the table floor declines
    // to the fallback just like one above the ceiling; the table floor is not an underflow bound.
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

  // Even `1e-307` is normal for `Double`, so the subnormal branch is unreachable above the
  // cutoff regardless of significand. Keeping the power calculation inside this guard preserves
  // the short dependency chain used by ordinary exponents; the full-range table should not tax
  // the ordinary working set just because it makes the extreme lower rows reachable.
  if exponent <= T.streamSubnormalCutoff {
    let subnormalPower2 =
      streamPowerOfTwoExponent(exponent) &+ upperBit &- leadingZeros &- T.streamMinExponent
    if subnormalPower2 <= 0 {
      // Subnormal, or small enough to round to zero. The shift is what the exponent field cannot
      // express, applied to the mantissa instead.
      guard -subnormalPower2 &+ 1 < 64 else { return T.streamFromBits(signBit) }
      mantissa >>= UInt64(-subnormalPower2 &+ 1)
      mantissa &+= mantissa & 1
      mantissa >>= 1
      // Rounding up out of the subnormal range lands on the smallest normal, which is spelled
      // with a biased exponent of one and the mantissa's implicit bit dropped -- and the value
      // that carried into bit `mantissaBits` already has exactly those low bits.
      let biased: UInt64 = mantissa < (1 << UInt64(mantissaBits)) ? 0 : 1
      return T.streamFromBits(
        signBit
          | T.StreamBits(truncatingIfNeeded: (biased << UInt64(mantissaBits)) | mantissa)
      )
    }
  }

  // The one case the approximation genuinely cannot separate: an exact halfway value in the
  // range where the significand is small enough for the product's low word to be all that
  // distinguishes round-up from round-down.
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
    // The cutoff guard above proves `power2` is positive. Spelling the conversion as truncating
    // keeps Swift from emitting a second sign check that leads only to an unreachable trap.
    signBit
      | T.StreamBits(
        truncatingIfNeeded: (UInt64(truncatingIfNeeded: power2) << UInt64(mantissaBits)) | mantissa
      )
  )
}
