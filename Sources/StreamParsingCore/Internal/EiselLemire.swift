import StreamParsingShims

// Eisel-Lemire: a decimal significand and a power of ten to the correctly rounded `Double`, with
// one 64x64 multiply in the common case and a second only when the first product's low bits
// cannot decide the rounding. It replaces the `magnitude <= 1 << 53 && |exponent| <= 22` exact
// path for everything that path could not reach -- which on `canada.json` was 91.2% of tokens,
// each of them building a `String` and calling the standard library's parser.
//
// The function declines rather than guesses. Two cases reach `nil`: a product whose low word is
// all ones, and the halfway case the 55-bit approximation cannot separate. Measured over the
// whole corpus plus ~500K generated cases against a correctly rounded oracle, that is 0.146% of
// `canada.json` and ~0.2% of uniformly random input, and the caller's existing fallback settles
// them. Nothing else is approximate: every case it does answer is bit-exact.
//
// `NumberInfo` already carries the inputs in the form this wants -- `magnitude` is the digits
// with the dot removed and `exponent` is the power of ten they are scaled by -- so no re-walk of
// the token is needed.

@inlinable
package var streamPow10MinExponent: Int { Int(stream_parsing_pow10_128_min_exponent) }

@inlinable
package var streamPow10MaxExponent: Int { Int(stream_parsing_pow10_128_max_exponent) }

// 52 explicit mantissa bits, a -1023 minimum exponent, 0x7FF for infinity: `Double`, spelled out
// because the kernel indexes and shifts by them rather than reading them from the type.
@inlinable package var streamDoubleMantissaBits: Int { 52 }
@inlinable package var streamDoubleMinExponent: Int { -1023 }
@inlinable package var streamDoubleInfinitePower: Int { 0x7FF }

// The top 128 bits of 10^q, and a second multiply only when the first cannot decide. The
// precision mask is 0x1FF: 64 - 55 bits, where 55 is the 52 explicit mantissa bits plus the
// three the rounding step needs.
@inlinable
@inline(__always)
package func streamPow10Product(_ exponent: Int, _ significand: UInt64) -> (high: UInt64, low: UInt64) {
  let index = 2 &* (exponent &- streamPow10MinExponent)
  let (firstHigh, firstLow) = significand.multipliedFullWidth(by: stream_parsing_pow10_128[index])
  guard firstHigh & 0x1FF == 0x1FF else { return (firstHigh, firstLow) }
  let (secondHigh, _) = significand.multipliedFullWidth(by: stream_parsing_pow10_128[index &+ 1])
  let (low, carried) = firstLow.addingReportingOverflow(secondHigh)
  return (carried ? firstHigh &+ 1 : firstHigh, low)
}

// `((152170 + 65536) * q) >> 16` is floor(q * log2(10)) over the table's exponent range, and 63
// accounts for the normalisation shift below.
@inlinable
@inline(__always)
package func streamPowerOfTwoExponent(_ exponent: Int) -> Int {
  ((152_170 &+ 65_536) &* exponent) >> 16 &+ 63
}

@inlinable
package func streamEiselLemire(magnitude: UInt64, exponent: Int, negative: Bool) -> Double? {
  let signBit: UInt64 = negative ? 1 << 63 : 0
  if magnitude == 0 || exponent < streamPow10MinExponent {
    // Only a true zero significand is a zero here: an exponent below the table's floor means the
    // value underflows every `Double`, including the subnormals.
    return magnitude == 0 ? Double(bitPattern: signBit) : nil
  }
  guard exponent <= streamPow10MaxExponent else { return nil }

  let leadingZeros = magnitude.leadingZeroBitCount
  let normalized = magnitude << UInt64(leadingZeros)
  let product = streamPow10Product(exponent, normalized)
  guard product.low != UInt64.max else { return nil }

  let upperBit = Int(product.high >> 63)
  var mantissa = product.high >> UInt64(upperBit &+ 9)
  var power2 =
    streamPowerOfTwoExponent(exponent) &+ upperBit &- leadingZeros &- streamDoubleMinExponent

  if power2 <= 0 {
    // Subnormal, or small enough to round to zero. The shift is what the exponent field cannot
    // express, applied to the mantissa instead.
    guard -power2 &+ 1 < 64 else { return Double(bitPattern: signBit) }
    mantissa >>= UInt64(-power2 &+ 1)
    mantissa &+= mantissa & 1
    mantissa >>= 1
    let biased: UInt64 = mantissa < (1 << UInt64(streamDoubleMantissaBits)) ? 0 : 1
    return Double(
      bitPattern: signBit | (biased << UInt64(streamDoubleMantissaBits)) | mantissa
    )
  }

  // The one case the approximation genuinely cannot separate: an exact halfway value in the
  // range where the significand is small enough for the product's low word to be all that
  // distinguishes round-up from round-down.
  if product.low <= 1, exponent >= -4, exponent <= 23, mantissa & 3 == 1 { return nil }

  mantissa &+= mantissa & 1
  mantissa >>= 1
  if mantissa >= (1 << UInt64(streamDoubleMantissaBits &+ 1)) {
    mantissa >>= 1
    power2 &+= 1
  }
  guard power2 < streamDoubleInfinitePower else { return nil }
  mantissa &= ~(1 << UInt64(streamDoubleMantissaBits))
  return Double(
    bitPattern: signBit | (UInt64(power2) << UInt64(streamDoubleMantissaBits)) | mantissa
  )
}
