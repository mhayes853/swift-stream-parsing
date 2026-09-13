import StreamParsingShims

// 10^exponent as an exact `Double`, or `nil` outside 0 ... 22.
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
@inlinable
@inline(__always)
func digitPow10Value(_ exponent: Int) -> Double? {
  // One unsigned compare covers both ends: a negative exponent wraps to a huge `UInt`.
  let count = UInt(UInt32(bitPattern: STREAM_PARSING_POW10_DOUBLE_COUNT))
  guard UInt(bitPattern: exponent) < count else { return nil }
  // The accessor is `static inline` in C and imports as an implicitly unwrapped pointer; the
  // unsafe unwrap is what keeps a null check out of the inlined copy. It can never be null --
  // it returns the address of a `.rodata` array.
  return stream_parsing_pow10_double().unsafelyUnwrapped[exponent]
}
