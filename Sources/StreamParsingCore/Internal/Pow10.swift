@inlinable
@inline(__always)
func digitPow10(_ exponent: Int) -> Double {
  if exponent >= 0 {
    if exponent < _digitPow10Table.count {
      return _digitPow10Table[exponent]
    }
    return _fastPow10(exponent)
  }

  let magnitude = -exponent
  if magnitude < _negativeDigitPow10Table.count {
    return _negativeDigitPow10Table[magnitude]
  }
  return 1.0 / _fastPow10(magnitude)
}

@usableFromInline
let _digitPow10Table: [Double] = [
  1,
  10,
  100,
  1_000,
  10_000,
  100_000,
  1_000_000,
  10_000_000,
  100_000_000,
  1_000_000_000,
  10_000_000_000,
  100_000_000_000,
  1_000_000_000_000,
  10_000_000_000_000,
  100_000_000_000_000,
  1_000_000_000_000_000,
  10_000_000_000_000_000,
  100_000_000_000_000_000,
  1_000_000_000_000_000_000,
  10_000_000_000_000_000_000
]

@usableFromInline
let _negativeDigitPow10Table = [
  1,
  0.1,
  0.01,
  0.001,
  0.0001,
  0.00001,
  0.000001,
  0.0000001,
  0.00000001,
  0.000000001,
  0.0000000001,
  0.00000000001,
  0.000000000001,
  0.0000000000001,
  0.00000000000001,
  0.000000000000001,
  0.0000000000000001,
  0.00000000000000001,
  0.000000000000000001,
  0.0000000000000000001,
  0.00000000000000000001
]

@inlinable
@inline(__always)
func _fastPow10(_ exponent: Int) -> Double {
  var result = 1.0
  var base = 10.0
  var power = exponent
  while power > 0 {
    if power & 1 == 1 {
      result *= base
    }
    power >>= 1
    base *= base
  }
  return result
}
