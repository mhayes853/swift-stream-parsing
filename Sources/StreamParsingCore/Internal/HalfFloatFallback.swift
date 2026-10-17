// Swift's binary16 string conversion can narrow from Float: for example,
// -131.68749999999994 becomes -131.75 instead of -131.625. Parsing through Double
// avoids that intermediate, but arbitrarily long decimals can still land on a
// Double that is exactly halfway between two halves. Settle those rare cases by
// comparing the complete token with the exact decimal expansion of the midpoint.
// This is cold fallback work; the ordinary Clinger/Eisel-Lemire path does none of it.
func streamParseHalfFallback<T: BinaryFloatingPoint>(
  _ bytes: Span<UInt8>,
  text: String,
  as type: T.Type
) -> T? {
  guard let parsed = Double(text), parsed.isFinite else { return nil }
  let magnitude = parsed.magnitude
  let candidate = min(T(magnitude), T.greatestFiniteMagnitude)
  let lower = Double(candidate) > magnitude ? candidate.nextDown : candidate
  // The same spacing also gives the overflow midpoint (65520 for binary16).
  let midpoint = Double(lower) + Double(lower.ulp) / 2
  let comparison: Int
  if magnitude < midpoint {
    comparison = -1
  } else if magnitude > midpoint {
    comparison = 1
  } else {
    comparison = streamCompareDecimalMagnitude(bytes, to: midpoint)
  }
  let roundUp = comparison > 0 || (comparison == 0 && lower.significandBitPattern & 1 != 0)
  let value = roundUp ? lower.nextUp : lower
  guard value.isFinite else { return nil }
  return parsed.sign == .minus ? -value : value
}

// Exact decimal expansion of a positive binary16 midpoint. Its denominator is
// at most 2^25, so integer long division needs no big integer or UInt128 runtime.
private func streamCompareDecimalMagnitude(_ bytes: Span<UInt8>, to midpoint: Double) -> Int {
  let denominator: UInt64 = 1 << 25
  let numerator = UInt64(midpoint * Double(denominator))
  var exact = Array(String(numerator / denominator).utf8)
  var remainder = numerator % denominator
  if remainder != 0 { exact.append(46) }
  while remainder != 0 {
    remainder *= 10
    exact.append(UInt8(remainder / denominator) + 48)
    remainder %= denominator
  }
  let input = streamNormalizedDecimal(bytes)
  let reference = exact.withUnsafeBufferPointer {
    streamNormalizedDecimal(Span(_unsafeElements: $0))
  }
  if input.digits.isEmpty { return -1 }
  if input.point != reference.point { return input.point < reference.point ? -1 : 1 }
  for index in 0..<max(input.digits.count, reference.digits.count) {
    let a = index < input.digits.count ? input.digits[index] : 48
    let b = index < reference.digits.count ? reference.digits[index] : 48
    if a != b { return a < b ? -1 : 1 }
  }
  return 0
}

// Retain significant digits (trailing zeros are harmless) and the decimal point's
// position relative to their first digit. Saturation is only for explicit exponents
// too large for Int; no realizable token length could offset one of those.
private func streamNormalizedDecimal(_ bytes: Span<UInt8>) -> (digits: [UInt8], point: Int) {
  var digits: [UInt8] = []
  digits.reserveCapacity(bytes.count)
  var index = bytes[0] == 45 ? 1 : 0
  var fraction = false
  var fractionDigits = 0
  while index < bytes.count {
    let byte = bytes[index]
    if byte == 101 || byte == 69 { break }
    if byte == 46 {
      fraction = true
    } else {
      if fraction { fractionDigits += 1 }
      if byte != 48 || !digits.isEmpty { digits.append(byte) }
    }
    index += 1
  }
  var exponent = 0
  var negativeExponent = false
  if index < bytes.count {
    index += 1
    if index < bytes.count, bytes[index] == 45 || bytes[index] == 43 {
      negativeExponent = bytes[index] == 45
      index += 1
    }
    while index < bytes.count {
      let digit = Int(bytes[index]) - 48
      exponent = exponent <= (Int.max - digit) / 10 ? exponent * 10 + digit : Int.max
      index += 1
    }
  }
  let point = (digits.count - fractionDigits)
    .addingReportingOverflow(
      negativeExponent ? -exponent : exponent
    )
  return (digits, point.overflow ? (negativeExponent ? Int.min : Int.max) : point.partialValue)
}
