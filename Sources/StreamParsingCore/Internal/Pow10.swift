import StreamParsingShims

// 10^exponent as a `Double`, or `nil` outside the range `Double` can express.
//
// The table is `stream_parsing_pow10_double_storage` in `Pow10_Double.c` -- one contiguous
// `.rodata` run of 633 entries covering 10^-324 ... 10^308, indexed by `exponent + 324`.
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
// exponent arrives as `abs(exponent)`, which is enough for the optimizer to drop the low half of
// the bounds check and the whole negative half of the table: what is left in
// `Double.init(streamParsing:info:)` is `cmp #0x134` and `ldr d1, [table, exponent, lsl #3]`.
@inlinable
@inline(__always)
func digitPow10Value(_ exponent: Int) -> Double? {
  // One unsigned compare covers both ends: a negative index wraps to a huge `UInt`.
  let index = exponent &- Int(STREAM_PARSING_POW10_DOUBLE_MIN_EXPONENT)
  let count = UInt(UInt32(bitPattern: STREAM_PARSING_POW10_DOUBLE_COUNT))
  guard UInt(bitPattern: index) < count else { return nil }
  // The accessor is `static inline` in C and imports as an implicitly unwrapped pointer; the
  // unsafe unwrap is what keeps a null check out of the inlined copy. It can never be null --
  // it returns the address of a `.rodata` array.
  return stream_parsing_pow10_double().unsafelyUnwrapped[index]
}
