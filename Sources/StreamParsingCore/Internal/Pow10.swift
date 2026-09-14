import StreamParsingShims

// The exact powers of ten, as `Double`, for exponents 0 ... 22.
//
// The table is `stream_parsing_pow10_double_storage` in `Pow10_Double.c`: 23 contiguous `.rodata`
// entries indexed directly by the positive exponent. 10^22 is the last exact entry because its
// odd factor, 5^22, is the largest that fits Double's 53-bit significand.
//
// It used to be two Swift `[Double]` globals. What that cost, read off the release binary rather
// than assumed: the optimizer does fold an array literal of constants into a statically
// initialized array object, so no `swift_once` ran at the use site -- but the objects landed in
// `__DATA` behind a 0x28-byte array header, the addressor and one-time-initialization functions
// were still emitted (and a build that does not get that fold, including a debug or Embedded one,
// really does pay them), and the two tables meant the sign of the exponent had to be branched on
// before either could be indexed, each with its own signed bounds check. The function stayed out
// of line and handed back an `Optional<Double>` in a register pair, which the caller then had to
// take apart.
//
// One `.rodata` table plus `@inline(__always)` collapses all of that. At the only call site the
// exponent arrives as `abs(exponent)`, so one unsigned compare simultaneously proves the table
// index and the exactness precondition before the direct indexed load.

// 23: `10^0 ... 10^22`.
@inlinable
@inline(__always)
var streamExactPow10Count: Int { Int(STREAM_PARSING_POW10_DOUBLE_COUNT) }

// 10^exponent with no bounds check. The caller owes `0 <= exponent < streamExactPow10Count`,
// which the generic conversion establishes with the same compare that proves the value is
// exactly representable in the destination, so a second one here would be redundant.
//
// The accessor is `static inline` in C and imports as an implicitly unwrapped pointer; the
// unsafe unwrap is what keeps a null check out of the inlined copy. It can never be null --
// it returns the address of a `.rodata` array.
@inlinable
@inline(__always)
func streamExactPow10(_ exponent: Int) -> Double {
  stream_parsing_pow10_double().unsafelyUnwrapped[exponent]
}

// The largest `k` for which `10^k` is exactly representable in `T`, clamped to the table.
//
// `10^k = 2^k * 5^k` is exact exactly when its odd factor `5^k` fits the significand, i.e.
// `5^k < 2^(significandBitCount + 1)`, i.e. `k <= (significandBitCount + 1) * log(2)/log(5)`.
// `28225/65536` is that ratio (0.4306766). 22 for `Double`, 10 for `Float`, 4 for `Float16`.
//
// The second term guards a format whose exponent range runs out before its significand does:
// `10^k` must also be finite, `k <= emax * log10(2)`, with `19728/65536 = 0.30103` and
// `emax = 2^(exponentBitCount - 1) - 1`. It binds for nothing in the standard library (307 for
// `Double`, 38 for `Float`, 4 for `Float16`) but costs nothing either -- both terms are
// compile-time constants once `T` is known.
@inlinable
@inline(__always)
func streamMaxExactPow10<T: BinaryFloatingPoint>(_ type: T.Type) -> Int {
  let byMantissa = ((T.significandBitCount &+ 1) &* 28225) >> 16
  // `emax` spelled with an explicit `Int`: left to inference, the Embedded (wasm) toolchain
  // typed the shifted literal as `Int128` and refused the `min` below.
  let emax: Int = (1 << (T.exponentBitCount &- 1)) &- 1
  let byExponent = (emax &* 19728) >> 16
  return min(min(byMantissa, byExponent), streamExactPow10Count &- 1)
}

// The largest integer magnitude `T` holds exactly: `2^(significandBitCount + 1)`, expressed in
// `UInt64` because that is what the accumulator hands over. A format with a significand as wide
// as the accumulator (`Float80`, 63 explicit bits) represents every `UInt64`, and saturating
// rather than shifting by 64 keeps that from trapping.
@inlinable
@inline(__always)
func streamMaxExactMagnitude<T: BinaryFloatingPoint>(_ type: T.Type) -> UInt64 {
  let bits = T.significandBitCount &+ 1
  return bits >= 64 ? UInt64.max : (1 << UInt64(bits))
}
