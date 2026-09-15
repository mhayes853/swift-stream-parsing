import StreamParsingShims

// The exact powers of ten 10^0 ... 10^22 as `Double` (5^22 is the largest odd factor that fits 53
// bits): `stream_parsing_pow10_double_storage` in `Pow10_Double.c`. Must stay a C `.rodata` table,
// not a Swift `[Double]` global, which costs an addressor, one-time init and signed bounds checks.
// See NEW_ARCHITECTURE.md, "The power-of-ten table".

// 23: `10^0 ... 10^22`.
@inlinable
@inline(__always)
var streamExactPow10Count: Int { Int(STREAM_PARSING_POW10_DOUBLE_COUNT) }

// 10^exponent with no bounds check: the caller owes `0 <= exponent < streamExactPow10Count`, proven
// by the same compare that proves exactness. The unsafe unwrap keeps a null check out of the
// inlined copy; the accessor returns a `.rodata` address.
@inlinable
@inline(__always)
func streamExactPow10(_ exponent: Int) -> Double {
  stream_parsing_pow10_double().unsafelyUnwrapped[exponent]
}

// The largest `k` with `10^k` exact in `T`, clamped to the table. Exact when `5^k` fits the
// significand, `k <= (significandBitCount + 1) * log(2)/log(5)` (28225/65536): 22 for `Double`, 10
// for `Float`. The second term keeps `10^k` finite, `k <= emax * log10(2)` (19728/65536); it binds
// for no standard type but folds to a constant.
@inlinable
@inline(__always)
func streamMaxExactPow10<T: BinaryFloatingPoint>(_ type: T.Type) -> Int {
  let byMantissa = ((T.significandBitCount &+ 1) &* 28225) >> 16
  // Explicit `Int`: inferred, the Embedded (wasm) toolchain typed this `Int128` and rejected `min`.
  let emax: Int = (1 << (T.exponentBitCount &- 1)) &- 1
  let byExponent = (emax &* 19728) >> 16
  return min(min(byMantissa, byExponent), streamExactPow10Count &- 1)
}

// The largest integer magnitude `T` holds exactly, `2^(significandBitCount + 1)`, as the
// accumulator's `UInt64`; saturates for `Float80`, whose significand is that wide.
@inlinable
@inline(__always)
func streamMaxExactMagnitude<T: BinaryFloatingPoint>(_ type: T.Type) -> UInt64 {
  let bits = T.significandBitCount &+ 1
  return bits >= 64 ? UInt64.max : (1 << UInt64(bits))
}
