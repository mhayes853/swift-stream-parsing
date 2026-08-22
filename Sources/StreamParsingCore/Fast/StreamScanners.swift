// Short indices and accumulators keep the scanner kernels close to their measured operations.
// swiftlint:disable identifier_name
#if canImport(simd)
  import simd
#endif
import StreamParsingShims

// MARK: - Whitespace and string runs

// Measured on arm64 over an 8 KB corpus at varying run lengths (MB/s):
//
//   run length      4       16      64     4096
//   scalar       1401     1480    1528     1548
//   SWAR          940     2373    5730     9817
//   SIMD16       2476     7469   12770    21411
//   SIMD32       1680     2987    9201    18480
//
// SIMD16 wins at every run length. SIMD32 loses on arm64 because NEON registers are 128 bits
// and it lowers to two operations plus a recombine.

@inlinable package var streamScannerVectorWidth: Int { 16 }

// The string scanner already loads every byte needed to find a quote, escape or control byte.
// Carrying the high-bit observation with the end index lets validated string values skip a second
// ASCII-only pass. The flag is exact: bytes after the first terminating lane are masked out.
@usableFromInline
package struct StreamStringRun: Hashable, Sendable {
  @usableFromInline package let end: Int
  @usableFromInline package let containsNonASCII: Bool

  @usableFromInline
  package init(end: Int, containsNonASCII: Bool) {
    self.end = end
    self.containsNonASCII = containsNonASCII
  }
}

@inlinable
@inline(__always)
package func streamVectorContainsNonASCII(_ bytes: SIMD16<UInt8>) -> Bool {
#if canImport(simd)
  simd_reduce_max(bytes) >= .utf8ContinuationFloor
#else
  any(bytes .>= SIMD16<UInt8>(repeating: .utf8ContinuationFloor))
#endif
}

@inlinable
@inline(__always)
package func streamStringRun(base: UnsafeRawPointer, from: Int, to: Int) -> StreamStringRun {
  if from < to {
    let first = base.load(fromByteOffset: from, as: UInt8.self)
    if first == .asciiQuote || first == .asciiBackslash || first < .asciiSpace {
      return StreamStringRun(end: from, containsNonASCII: false)
    }
  }

  let quote = SIMD16<UInt8>(repeating: .asciiQuote)
  let backslash = SIMD16<UInt8>(repeating: .asciiBackslash)
  let space = SIMD16<UInt8>(repeating: .asciiSpace)
  let lanes = SIMD16<UInt8>(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)

  var scanned = SIMD16<UInt8>.zero
  var i = from
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let hit = chunk .== quote .| chunk .== backslash .| chunk .< space
    if any(hit) {
#if canImport(simd)
      let candidates = SIMD16<UInt8>(repeating: 16).replacing(with: lanes, where: hit)
      let lane = Int(simd_reduce_min(candidates))
      let beforeHit = lanes .< SIMD16<UInt8>(repeating: UInt8(lane))
      let prefix = SIMD16<UInt8>.zero.replacing(with: chunk, where: beforeHit)
      return StreamStringRun(
        end: i &+ lane,
        containsNonASCII: streamVectorContainsNonASCII(scanned | prefix)
      )
#else
      for lane in 0..<streamScannerVectorWidth where hit[lane] {
        let beforeHit = lanes .< SIMD16<UInt8>(repeating: UInt8(lane))
        let prefix = SIMD16<UInt8>.zero.replacing(with: chunk, where: beforeHit)
        return StreamStringRun(
          end: i &+ lane,
          containsNonASCII: streamVectorContainsNonASCII(scanned | prefix)
        )
      }
#endif
    }
    scanned |= chunk
    i &+= streamScannerVectorWidth
  }
  var containsNonASCII = streamVectorContainsNonASCII(scanned)
  while i < to {
    let byte = base.load(fromByteOffset: i, as: UInt8.self)
    if byte == .asciiQuote || byte == .asciiBackslash || byte < .asciiSpace {
      return StreamStringRun(end: i, containsNonASCII: containsNonASCII)
    }
    containsNonASCII = containsNonASCII || byte >= .utf8ContinuationFloor
    i &+= 1
  }
  return StreamStringRun(end: to, containsNonASCII: containsNonASCII)
}

// This runs before every structural byte, and how much whitespace it finds is a property of the
// document, not of JSON. Measured over the corpus, as runs *outside* strings:
//
//   document        whitespace    runs   1 byte   >= 16 bytes
//   canada                   0%       0        -             -
//   llm_message             17%       0        -             -   (all of it inside string values)
//   github_events           19%    2526      45%            0%
//   gsoc-2018               19%   41713      45%            0%
//   twitter                 26%   28826      46%            2%
//   citm_catalog            71%   76337      34%           59%
//
// So it is one test in front of two scans. Every JSON whitespace byte is <= 0x20 and every byte
// that may legally follow one is > 0x20, so a single compare settles the no-whitespace case —
// which is the whole of `canada` and `llm_message` and half of every other document — without
// touching a vector. What survives is a run, and runs are scanned SIMD16 like every other class.
//
// **The inlined body has to stay this small, and that is the constraint, not the scan.** This is
// `@inline(__always)` into the parse loop, so anything spelled here is paid for in that loop's
// register pressure by every document, including ones with no whitespace at all. Two further
// variants were measured and both were rejected on documents the added code never runs on:
//
//   variant                            citm    twitter   twitterescaped   unicode escapes
//   vector body inlined here          +22%       +7%             -18%              -35%
//   one byte run peeled here          +20%       +8%             -18%              -34%
//   **shipped: one compare, then out of line**  **+21%**  **+7%**   **-1%**        **-2%**
//
// The width test below is what keeps the byte fed path off the vector body: `to &- from` is 1 at
// every call there, and routing that through it splats four constants to scan a single byte,
// which cost `twitter` byte by byte 20%.
@inlinable
@inline(__always)
package func streamWhitespaceEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  if from < to, base.load(fromByteOffset: from, as: UInt8.self) > .asciiSpace { return from }
  if to &- from < streamScannerVectorWidth {
    return streamWhitespaceScalarEnd(base: base, from: from, to: to)
  }
  return streamWhitespaceRunEnd(base: base, from: from, to: to)
}

@inlinable
@inline(__always)
package func streamWhitespaceScalarEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  var i = from
  while i < to {
    let byte = base.load(fromByteOffset: i, as: UInt8.self)
    if byte != .asciiSpace, byte != .asciiTab, byte != .asciiLineFeed,
      byte != .asciiCarriageReturn
    {
      return i
    }
    i &+= 1
  }
  return i
}

// Kept out of line deliberately. Inlining the vector body into the parse loop measured 18-35%
// *slower* on escape dense documents, which contain no whitespace for it to scan at all: the
// loop's own register pressure is the cost, not the scan.
@inlinable
@inline(never)
package func streamWhitespaceRunEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  var i = from
  let space = SIMD16<UInt8>(repeating: .asciiSpace)
  let tab = SIMD16<UInt8>(repeating: .asciiTab)
  let lineFeed = SIMD16<UInt8>(repeating: .asciiLineFeed)
  let carriageReturn = SIMD16<UInt8>(repeating: .asciiCarriageReturn)

  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let hit = chunk .== space .| chunk .== tab .| chunk .== lineFeed .| chunk .== carriageReturn
    if !all(hit) {
      let miss = .!hit
#if canImport(simd)
      let lanes = SIMD16<UInt8>(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
      let candidates = SIMD16<UInt8>(repeating: 16).replacing(with: lanes, where: miss)
      return i &+ Int(simd_reduce_min(candidates))
#else
      for lane in 0..<streamScannerVectorWidth where miss[lane] { return i &+ lane }
#endif
    }
    i &+= streamScannerVectorWidth
  }
  return streamWhitespaceScalarEnd(base: base, from: i, to: to)
}

// MARK: - Key words

// Eight key bytes as one little-endian word. This is the first thing a generated matcher does to
// every object key in a document, so it is on the hot path of every object heavy parse.
//
// It used to be a byte at a time loop. The wide load is bounded by the span, and has to be:
// a key span is a borrow into the parser's input, with the document's own bytes behind it, and
// `paddedWord` is public on `Span<UInt8>` besides. (Sixteen zeroed bytes used to follow every key
// so a matcher could overread; nothing ever read them, and the copy that produced them is gone.)
//
// Under eight bytes it is a halving ladder rather than a vector. NEON has no masked load, so a
// partial vector cannot be read without either overreading or a per lane loop, and the ladder
// settles any tail in at most three loads and three predictable branches against the loop's seven
// iterations. Most JSON keys land here — `id`, `text`, `user`, `name` — so the tail is the case
// worth spelling out, not the fallback.
@inlinable
@inline(__always)
package func streamPaddedWord(base: UnsafeRawPointer, from: Int, to: Int) -> UInt64 {
  let available = to &- from
  if available >= 8 {
    return UInt64(littleEndian: base.loadUnaligned(fromByteOffset: from, as: UInt64.self))
  }
  guard available > 0 else { return 0 }

  var word: UInt64 = 0
  var offset = from
  if available & 4 != 0 {
    word = UInt64(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
    offset &+= 4
  }
  if available & 2 != 0 {
    let half = UInt64(UInt16(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
    word |= half << UInt64((offset &- from) &* 8)
    offset &+= 2
  }
  if available & 1 != 0 {
    let byte = UInt64(base.load(fromByteOffset: offset, as: UInt8.self))
    word |= byte << UInt64((offset &- from) &* 8)
  }
  return word
}

extension Span where Element == UInt8 {
  // A generated matcher switches on the leading word, then checks the count and any remaining
  // words. The count is load bearing even below eight bytes: JSON keys can contain a decoded NUL,
  // which is otherwise indistinguishable from the zero padding.
  @inlinable
  @inline(__always)
  public func paddedLeadingWord() -> UInt64 {
    self.paddedWord(at: 0)
  }

  @inlinable
  @inline(__always)
  public func paddedWord(at start: Int) -> UInt64 {
    self.withUnsafeBufferPointer { buffer in
      streamPaddedWord(
        base: UnsafeRawPointer(buffer.baseAddress.unsafelyUnwrapped),
        from: start,
        to: buffer.count
      )
    }
  }

  @inlinable
  @inline(__always)
  public func matches(_ other: Span<UInt8>) -> Bool {
    guard self.count == other.count else { return false }
    var i = 0
    while i < self.count {
      if self[i] != other[i] { return false }
      i &+= 1
    }
    return true
  }
}

// MARK: - Key hashing and comparison

// A key's hash, vectored where the length allows it.
//
// This replaced FNV-1a walked one byte at a time. FNV's cost is not the arithmetic but its shape:
// every byte's multiply depends on the previous byte's, so a twelve byte key is a chain of twelve
// multiply latencies that no amount of instruction level parallelism can overlap. `key_number_42`
// is thirteen bytes, which is what a counts-style document is made of.
//
// Two accumulators fed from one SIMD16 load break that chain in half, and the whole 16 byte block
// costs one vector load, one vector xor and two multiplies that issue together.
//
// The tail is a bounded word ladder rather than a masked vector, for the reason `streamPaddedWord`
// already documents: NEON has no masked load, so a partial vector cannot be read without either
// overreading or a per lane loop. Keys shorter than sixteen bytes — which is most of them — skip
// the loop entirely and cost at most two bounded loads.
//
// Nothing here is serialized, so the byte order the words are read in only has to agree with
// itself: a key of a given length always takes the same path, and both entry points hash through
// this function.
@inlinable
@inline(__always)
package func streamHashBytes(base: UnsafeRawPointer, count: Int) -> UInt64 {
  let prime0: UInt64 = 0x9E37_79B9_7F4A_7C15
  let prime1: UInt64 = 0xC2B2_AE3D_27D4_EB4F

  var a = prime0 ^ UInt64(UInt(bitPattern: count))
  var b = prime1

  var i = 0
  while i &+ 16 <= count {
    let block = unsafeBitCast(
      base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self), to: SIMD2<UInt64>.self
    )
    a = (a ^ block[0]) &* prime0
    b = (b ^ block[1]) &* prime1
    i &+= 16
  }

  if i < count {
    let width = Swift.min(count &- i, 8)
    a = (a ^ streamPaddedWord(base: base, from: i, to: i &+ width)) &* prime0
    i &+= width
    if i < count {
      b = (b ^ streamPaddedWord(base: base, from: i, to: count)) &* prime1
    }
  }

  // Avalanche, so that keys differing in one byte land in different buckets rather than in
  // adjacent ones: the table masks the low bits and linear probing punishes clustering.
  var hash = a ^ b
  hash ^= hash >> 33
  hash = hash &* 0xFF51_AFD7_ED55_8CCD
  hash ^= hash >> 29
  return hash
}

// Byte equality, sixteen bytes at a time.
//
// The lanes are xored and the difference read as two words, rather than compared into a mask:
// `any(mask)` lowers to an out-of-line reduction call, which is the same reason
// `streamIsEightDigits` spells its all-lanes test by hand.
@inlinable
@inline(__always)
package func streamBytesEqual(
  _ lhs: UnsafeRawPointer, _ rhs: UnsafeRawPointer, count: Int
) -> Bool {
  var i = 0
  while i &+ 16 <= count {
    let left = lhs.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let right = rhs.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let difference = unsafeBitCast(left ^ right, to: SIMD2<UInt64>.self)
    guard difference[0] | difference[1] == 0 else { return false }
    i &+= 16
  }
  while i < count {
    let width = Swift.min(count &- i, 8)
    guard streamPaddedWord(base: lhs, from: i, to: i &+ width)
      == streamPaddedWord(base: rhs, from: i, to: i &+ width)
    else { return false }
    i &+= width
  }
  return true
}

// Lexicographic byte ordering, sixteen bytes at a time. The return follows `memcmp`: negative,
// zero or positive according to the first unequal byte. Locating that byte from the xor keeps
// the agreeing prefix in registers rather than walking the underlying memory a second time.
@inlinable
@inline(__always)
package func streamCompareBytes(
  _ lhs: UnsafeRawPointer, _ rhs: UnsafeRawPointer, count: Int
) -> Int {
  var i = 0
  while i &+ 16 <= count {
    let left = lhs.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let right = rhs.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let difference = unsafeBitCast(left ^ right, to: SIMD2<UInt64>.self)
    if difference[0] | difference[1] != 0 {
      let half = difference[0] == 0 ? 1 : 0
      let bits = UInt64(littleEndian: difference[half])
      let lane = half &* 8 &+ bits.trailingZeroBitCount / 8
      return left[lane] < right[lane] ? -1 : 1
    }
    i &+= 16
  }
  while i < count {
    let width = Swift.min(count &- i, 8)
    let left = streamPaddedWord(base: lhs, from: i, to: i &+ width)
    let right = streamPaddedWord(base: rhs, from: i, to: i &+ width)
    let difference = left ^ right
    if difference != 0 {
      let shift = difference.trailingZeroBitCount & ~7
      let leftByte = UInt8(truncatingIfNeeded: left >> shift)
      let rightByte = UInt8(truncatingIfNeeded: right >> shift)
      return leftByte < rightByte ? -1 : 1
    }
    i &+= width
  }
  return 0
}

// MARK: - Number scanning

// Finds the first byte outside the number token class: digits, '.', 'e', 'E', '+', '-'. The
// scan is greedy — placement is the whole-token parse's business — which is what makes it
// stateless and lets SIMD16 test all six membership conditions per lane. Strategy table in
// NEW_ARCHITECTURE.md: 12.6–23.4 ns/number against 19.5–91.8 for the fused per-byte scan.
//
// On arm64 the membership test is two table lookups instead of six compares: `tbl` only indexes
// sixteen entries directly, so a byte is split into its high and low nibbles, each nibble looks
// up a bitmask of which number classes are possible for it (`streamNumberClassHighTable`,
// `streamNumberClassLowTable`), and `vtstq_u8` tests whether the two bitmasks share a set bit.
// Disassembly confirms `ldr, ushr, tbl, and, tbl, cmtst` — six instructions classifying the whole
// block, against the portable path's `ldr` plus eleven (six compares and their `orr`s).
//
// The "did every lane match" check is `streamVectorIsNonZero` on the bitwise complement of the
// hit bytes, not `all(hit)`: bitcasting the `vtstq_u8` result to a `SIMDMask` and calling `all()`
// on that compiled to an actual `bl` — a real out-of-line call, not the `uminv` reduction `all()`
// gives for a mask built directly from a compare (confirmed by disassembling the portable path's
// own `all(hit)` below, which does lower to `uminv` cleanly). `all()`'s fast path apparently only
// recognizes a mask it can see was built from a compare; a mask that arrives by `unsafeBitCast`
// loses that, silently, with no diagnostic. `tbl`, `cmtst` and the compare-then-`all()` shape all
// have no portable spelling, so the six-compare chain stays as the fallback, untouched: its
// `all(hit)` and unrolled-tail shape were already measured against a `uminv` reduction and tuned,
// per the comment below, and that tuning is independent of the arm64 path's own kernel.
@inlinable
@inline(__always)
package func streamNumberRunEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  #if arch(arm64)
    return streamNumberRunEndShimmed(base: base, from: from, to: to)
  #else
    return streamNumberRunEndScalar(base: base, from: from, to: to)
  #endif
}

// Reachable with the arm64 fast path forced off, so tests can hold it to the same oracle as the
// vector path on a machine that has both.
@inlinable
@inline(never)
package func streamNumberRunEndPortable(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  streamNumberRunEndScalar(base: base, from: from, to: to)
}

// bit0 digit-possible, bit1 dot-possible, bit2 plus-possible, bit3 dash-possible, bit4
// E/e-possible. Indexed by a byte's high nibble.
@inlinable
package var streamNumberClassHighTable: SIMD16<UInt8> {
  SIMD16<UInt8>(0, 0, 0b0_1110, 0b0_0001, 0b1_0000, 0, 0b1_0000, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

// Indexed by a byte's low nibble. Low nibble 5 carries both digit ('5' is 0x35) and E/e ('E' is
// 0x45, 'e' is 0x65) bits; the high nibble table resolves which one applies, or neither — '%' is
// 0x25, whose high nibble carries none of the bits low nibble 5 offers.
@inlinable
package var streamNumberClassLowTable: SIMD16<UInt8> {
  SIMD16<UInt8>(
    0b0_0001, 0b0_0001, 0b0_0001, 0b0_0001, 0b0_0001, 0b1_0001, 0b0_0001, 0b0_0001,
    0b0_0001, 0b0_0001, 0, 0b0_0100, 0, 0b0_1000, 0b0_0010, 0
  )
}

#if arch(arm64)
  @inlinable
  @inline(__always)
  package func streamNumberRunEndShimmed(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
    var i = from
    let highTable = streamNumberClassHighTable
    let lowTable = streamNumberClassLowTable
    let nibbleMask = SIMD16<UInt8>(repeating: 0x0F)
    while i &+ streamScannerVectorWidth <= to {
      let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
      let high = stream_parsing_tbl1q_u8(highTable, chunk &>> 4)
      let low = stream_parsing_tbl1q_u8(lowTable, chunk & nibbleMask)
      let hitBytes = vtstq_u8(high, low)
      if streamVectorIsNonZero(~hitBytes) {
        for lane in 0..<streamScannerVectorWidth where hitBytes[lane] == 0 { return i &+ lane }
      }
      i &+= streamScannerVectorWidth
    }
    return streamNumberRunEndTail(base: base, from: i, to: to)
  }
#endif

@inlinable
@inline(__always)
package func streamNumberRunEndScalar(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  var i = from
  let zero = SIMD16<UInt8>(repeating: .asciiZero)
  let ten = SIMD16<UInt8>(repeating: 10)
  let dot = SIMD16<UInt8>(repeating: .asciiDot)
  let lowerE = SIMD16<UInt8>(repeating: .asciiLowerE)
  let caseBit = SIMD16<UInt8>(repeating: 0x20)
  let plus = SIMD16<UInt8>(repeating: .asciiPlus)
  let dash = SIMD16<UInt8>(repeating: .asciiDash)
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    var hit = (chunk &- zero) .< ten .| chunk .== dot
    hit .|= (chunk | caseBit) .== lowerE
    hit .|= chunk .== plus
    hit .|= chunk .== dash
    if !all(hit) {
      // The per lane loop, deliberately: it unrolls into sixteen independent `umov` + branch
      // pairs, and for a miss in the first few lanes — every number under sixteen digits — that
      // resolves in one move plus predicted branches. The `uminv` reduction the other scanners
      // use was measured here and lost: `citm_catalog` +10.5%, nested arrays +11%, against
      // -2% on `canada`, because its `bsl` → `uminv` → `fmov` chain is dependent latency that a
      // short number pays in full while the ladder exits early.
      for lane in 0..<streamScannerVectorWidth where !hit[lane] { return i &+ lane }
    }
    i &+= streamScannerVectorWidth
  }
  return streamNumberRunEndTail(base: base, from: i, to: to)
}

@inlinable
@inline(__always)
package func streamNumberRunEndTail(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  var i = from
  while i < to {
    let byte = base.load(fromByteOffset: i, as: UInt8.self)
    let isNumber =
      byte &- .asciiZero < 10 || byte == .asciiDot || byte == .asciiDash || byte == .asciiPlus
      || (byte | 0x20) == .asciiLowerE
    if !isNumber { return i }
    i &+= 1
  }
  return to
}

// The classic 8-digit conversion as a SIMD lane tree: '0'-biased bytes are combined pairwise,
// then the lane count halves each stage, widening only where the next place value needs it.
// Every stage is exact — two digits still fit a byte, four fit a `UInt16` — so the block agrees
// with the scalar loop and only the accumulate below wraps, keeping overflowed magnitudes
// congruent (mod 2^64) between the two paths.
//
// This replaced a 64-bit SWAR form of the same block, measured 7–13% faster wherever the block
// fires. Strategy table in NEW_ARCHITECTURE.md.
@inlinable
@inline(__always)
package func streamParseEightDigits(_ chunk: SIMD8<UInt8>) -> UInt64 {
  let digits = chunk &- SIMD8<UInt8>(repeating: .asciiZero)
  let pairs = SIMD4<UInt16>(truncatingIfNeeded: digits.evenHalf &* 10 &+ digits.oddHalf)
  let quads = pairs.evenHalf &* 100 &+ pairs.oddHalf
  return UInt64(quads[0]) &* 10_000 &+ UInt64(quads[1])
}

// `all(mask)` lowers to an out-of-line `SIMD.max()` call, which also forces a stack frame onto
// the accumulate loop below, so the all-lanes test is spelled as one 64-bit compare over a 0/1
// lane vector. The comparand is byte-symmetric, so the bitcast is endian-independent.
@inlinable
@inline(__always)
package func streamIsEightDigits(_ chunk: SIMD8<UInt8>) -> Bool {
  let over = (chunk &- SIMD8<UInt8>(repeating: .asciiZero)) .>= SIMD8<UInt8>(repeating: 10)
  let lanes = SIMD8<UInt8>(repeating: 1).replacing(with: 0, where: over)
  return unsafeBitCast(lanes, to: UInt64.self) == 0x0101_0101_0101_0101
}

// Accumulates a digit run into `magnitude`, returning the run's end. Eight-digit blocks go
// through the SIMD conversion; the 17–19 digit run this pays for most is a document id.
@inlinable
@inline(__always)
package func streamAccumulateDigits(
  base: UnsafeRawPointer, from: Int, to: Int, into magnitude: inout UInt64
) -> Int {
  var index = from
  while index &+ 8 <= to {
    let chunk = base.loadUnaligned(fromByteOffset: index, as: SIMD8<UInt8>.self)
    guard streamIsEightDigits(chunk) else { break }
    magnitude = magnitude &* 100_000_000 &+ streamParseEightDigits(chunk)
    index &+= 8
  }
  while index < to {
    let digit = base.load(fromByteOffset: index, as: UInt8.self) &- .asciiZero
    guard digit < 10 else { break }
    magnitude = magnitude &* 10 &+ UInt64(digit)
    index &+= 1
  }
  return index
}

// `\u` as one little-endian halfword. The second escape of a surrogate pair is the one place two
// known adjacent bytes are tested, so it is one load and one compare rather than two of each.
// Built from the byte constants rather than written as a literal, and read back through
// `UInt16(littleEndian:)`, so it does not depend on the host's byte order.
@inlinable
package var streamUnicodeEscapePrefix: UInt16 {
  UInt16(UInt8.asciiBackslash) | (UInt16(UInt8.asciiLowerU) << 8)
}

// Four hex digits in one shot: fold case with the 0x20 bit (which digits already carry), test the
// digit and letter ranges together, select the nibbles from whichever matched, and weight them by
// place value. Returns nil unless all four are hex, so the caller can fall back rather than having
// to report which one was not.
@inlinable
@inline(__always)
package func streamHexQuad(base: UnsafeRawPointer, from: Int) -> UInt32? {
  let bytes = base.loadUnaligned(fromByteOffset: from, as: SIMD4<UInt8>.self)
  let digits = bytes &- SIMD4<UInt8>(repeating: .asciiZero)
  let letters = (bytes | SIMD4<UInt8>(repeating: 0x20)) &- SIMD4<UInt8>(repeating: .asciiLowerA)
  let isDigit = digits .< SIMD4<UInt8>(repeating: 10)
  let isLetter = letters .< SIMD4<UInt8>(repeating: 6)
  guard all(isDigit .| isLetter) else { return nil }
  let nibbles = SIMD4<UInt8>.zero
    .replacing(with: digits, where: isDigit)
    .replacing(with: letters &+ SIMD4<UInt8>(repeating: 10), where: isLetter)
  let weighted =
    SIMD4<UInt16>(truncatingIfNeeded: nibbles) &* SIMD4<UInt16>(0x1000, 0x100, 0x10, 1)
  return UInt32(weighted.wrappedSum())
}

// A direct byte-to-byte map for JSON's eight simple escapes. Zero means "not a simple escape";
// no valid simple escape decodes to NUL, so the sentinel costs no separate validity table. A
// `StaticString` keeps the 128 bytes in read-only storage rather than constructing an `Array` at
// startup, which matters to the parser's one-allocation fast path and to Embedded Swift.
//
// The parser handles `u` before asking this table: Unicode escapes carry four more bytes and
// cannot be represented by a one-byte result.
// swift-format-ignore
@usableFromInline
let streamSimpleEscapeTable: StaticString = """
\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\"\0\0\0\0\0\
\0\0\0\0\0\0\0/\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\
\0\0\0\0\0\0\0\0\0\0\0\0\\\0\0\0\0\0\u{8}\0\0\0\u{c}\0\0\0\0\0\0\0\u{a}\0\0\0\
\u{d}\0\u{9}\0\0\0\0\0\0\0\0\0\0\0
"""

@inlinable
@inline(__always)
package func streamDecodeSimpleEscape(_ byte: UInt8) -> UInt8? {
  guard byte < 128 else { return nil }
  let decoded = streamSimpleEscapeTable.utf8Start[Int(byte)]
  return decoded == 0 ? nil : decoded
}

// Lets the full UTF-8 validator run only on the rare non-ASCII run.
@inlinable
@inline(__always)
package func streamContainsNonASCII(base: UnsafeRawPointer, from: Int, to: Int) -> Bool {
#if !canImport(simd)
  let high = SIMD16<UInt8>(repeating: .utf8ContinuationFloor)
#endif
  var i = from
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
#if canImport(simd)
    if simd_reduce_max(chunk) >= .utf8ContinuationFloor { return true }
#else
    if any(chunk .>= high) { return true }
#endif
    i &+= streamScannerVectorWidth
  }
  while i < to {
    if base.load(fromByteOffset: i, as: UInt8.self) >= .utf8ContinuationFloor { return true }
    i &+= 1
  }
  return false
}

// MARK: - Lane shifts

// `previous`'s last `count` lanes followed by `current`'s first `16 - count`: the view of "the
// byte `count` back" for every lane of `current`, given the block before it. On arm64 this is
// one `ext` through the shim; the portable form does the same thing on the two 64-bit halves —
// shift each half up by `8 * count` bits and OR in the bits that crossed from the half below,
// which for the low half is the top of `previous` — so it never leaves vector registers and
// never touches memory. Little-endian lane order, which every supported target has. `count` is
// a literal at every call site, so the switch folds.
@inlinable
@inline(__always)
package func streamBytesShiftedIn(
  from previous: SIMD16<UInt8>, into current: SIMD16<UInt8>, count: Int
) -> SIMD16<UInt8> {
  #if arch(arm64)
    return streamBytesShiftedInShimmed(from: previous, into: current, count: count)
  #else
    return streamBytesShiftedInPortable(from: previous, into: current, count: count)
  #endif
}

#if arch(arm64)
  @inlinable
  @inline(__always)
  package func streamBytesShiftedInShimmed(
    from previous: SIMD16<UInt8>, into current: SIMD16<UInt8>, count: Int
  ) -> SIMD16<UInt8> {
    switch count {
    case 1: return stream_parsing_extq_u8_1(previous, current)
    case 2: return stream_parsing_extq_u8_2(previous, current)
    default: return stream_parsing_extq_u8_3(previous, current)
    }
  }
#endif

@inlinable
@inline(__always)
package func streamBytesShiftedInPortable(
  from previous: SIMD16<UInt8>, into current: SIMD16<UInt8>, count: Int
) -> SIMD16<UInt8> {
  let bits = UInt64(truncatingIfNeeded: count &* 8)
  let currentWords = unsafeBitCast(current, to: SIMD2<UInt64>.self)
  let previousWords = unsafeBitCast(previous, to: SIMD2<UInt64>.self)
  let shifted = currentWords &<< bits
  let carried = SIMD2<UInt64>(previousWords[1], currentWords[0]) &>> (64 &- bits)
  return unsafeBitCast(shifted | carried, to: SIMD16<UInt8>.self)
}

// MARK: - UTF-8 validation

// Keiser and Lemire's lookup validator ("Validating UTF-8 In Less Than One Instruction Per
// Byte"). Every UTF-8 error is visible in a window of two adjacent bytes plus one structural
// fact — a continuation is required after a three or four byte lead — so a sixteen byte block
// is validated at once: the high nibble of the previous byte, its low nibble and the high
// nibble of the current byte each index a table of error classes, the three results are ANDed,
// and the structural fact is XORed in. The "previous byte" views come from the block before,
// carried across the loop and lane shifted in. On arm64 the three lookups are `tbl` and the
// three shifts are `ext`, through the `StreamParsingShims` wrappers; everywhere else the same
// classes are recomputed with range compares and the shifts are 64-bit arithmetic, which is
// more instructions and still none of the scalar walk's per-sequence branches.
//
// It answers only valid or not: an invalid run is rare, and the parser's scalar walk then finds
// the byte and reports it, which keeps every error offset exactly where `ErrorOffsetTests` pins
// it. `completePendingUTF8` is untouched — a sequence split by a chunk is reassembled and
// checked there, before any run is scanned.

@usableFromInline
package enum StreamUTF8ErrorClass {
  @usableFromInline package static let tooShort: UInt8 = 1 << 0
  @usableFromInline package static let tooLong: UInt8 = 1 << 1
  @usableFromInline package static let overlong3: UInt8 = 1 << 2
  @usableFromInline package static let tooLarge: UInt8 = 1 << 3
  @usableFromInline package static let surrogate: UInt8 = 1 << 4
  @usableFromInline package static let overlong2: UInt8 = 1 << 5
  @usableFromInline package static let tooLarge1000: UInt8 = 1 << 6
  @usableFromInline package static let overlong4: UInt8 = 1 << 6
  @usableFromInline package static let twoContinuations: UInt8 = 1 << 7
  @usableFromInline package static let carry: UInt8 = tooShort | tooLong | twoContinuations
}

// Indexed by the high nibble of the previous byte.
@inlinable
package var streamUTF8PreviousHighTable: SIMD16<UInt8> {
  typealias C = StreamUTF8ErrorClass
  return SIMD16<UInt8>(
    C.tooLong, C.tooLong, C.tooLong, C.tooLong, C.tooLong, C.tooLong, C.tooLong, C.tooLong,
    C.twoContinuations, C.twoContinuations, C.twoContinuations, C.twoContinuations,
    C.tooShort | C.overlong2,
    C.tooShort,
    C.tooShort | C.overlong3 | C.surrogate,
    C.tooShort | C.tooLarge | C.tooLarge1000 | C.overlong4
  )
}

// Indexed by the low nibble of the previous byte.
@inlinable
package var streamUTF8PreviousLowTable: SIMD16<UInt8> {
  typealias C = StreamUTF8ErrorClass
  return SIMD16<UInt8>(
    C.carry | C.overlong3 | C.overlong2 | C.overlong4,
    C.carry | C.overlong2,
    C.carry, C.carry,
    C.carry | C.tooLarge,
    C.carry | C.tooLarge | C.tooLarge1000,
    C.carry | C.tooLarge | C.tooLarge1000,
    C.carry | C.tooLarge | C.tooLarge1000,
    C.carry | C.tooLarge | C.tooLarge1000,
    C.carry | C.tooLarge | C.tooLarge1000,
    C.carry | C.tooLarge | C.tooLarge1000,
    C.carry | C.tooLarge | C.tooLarge1000,
    C.carry | C.tooLarge | C.tooLarge1000,
    C.carry | C.tooLarge | C.tooLarge1000 | C.surrogate,
    C.carry | C.tooLarge | C.tooLarge1000,
    C.carry | C.tooLarge | C.tooLarge1000
  )
}

// Indexed by the high nibble of the current byte.
@inlinable
package var streamUTF8CurrentHighTable: SIMD16<UInt8> {
  typealias C = StreamUTF8ErrorClass
  return SIMD16<UInt8>(
    C.tooShort, C.tooShort, C.tooShort, C.tooShort, C.tooShort, C.tooShort, C.tooShort, C.tooShort,
    C.tooLong | C.overlong2 | C.twoContinuations | C.overlong3 | C.tooLarge1000 | C.overlong4,
    C.tooLong | C.overlong2 | C.twoContinuations | C.overlong3 | C.tooLarge,
    C.tooLong | C.overlong2 | C.twoContinuations | C.surrogate | C.tooLarge,
    C.tooLong | C.overlong2 | C.twoContinuations | C.surrogate | C.tooLarge,
    C.tooShort, C.tooShort, C.tooShort, C.tooShort
  )
}

@inlinable
@inline(__always)
package func streamVectorIsNonZero(_ bytes: SIMD16<UInt8>) -> Bool {
  let words = unsafeBitCast(bytes, to: SIMD2<UInt64>.self)
  return words[0] | words[1] != 0
}

// A mask as bytes, 0xFF where set: the mask's own storage, read as unsigned.
@inlinable
@inline(__always)
package func streamMaskBytes(_ mask: SIMDMask<SIMD16<Int8>>) -> SIMD16<UInt8> {
  unsafeBitCast(mask, to: SIMD16<UInt8>.self)
}

// Whether a block holds an error, given the three views of the bytes before each lane. On arm64
// the kernel is one shim call; the portable form recomputes the same classes with range
// compares on the views, which are loaded vectors, so the lane-loop operators vectorize.
#if arch(arm64)
  @inlinable
  @inline(__always)
  package func streamUTF8BlockIsInvalidShimmed(
    current: SIMD16<UInt8>,
    previous1: SIMD16<UInt8>,
    previous2: SIMD16<UInt8>,
    previous3: SIMD16<UInt8>
  ) -> Bool {
    streamVectorIsNonZero(
      stream_parsing_utf8_block_errors(
        current, previous1, previous2, previous3,
        streamUTF8PreviousHighTable, streamUTF8PreviousLowTable, streamUTF8CurrentHighTable
      )
    )
  }
#endif

@inlinable
@inline(__always)
package func streamUTF8BlockIsInvalidPortable(
  current: SIMD16<UInt8>,
  previous1: SIMD16<UInt8>,
  previous2: SIMD16<UInt8>,
  previous3: SIMD16<UInt8>
) -> Bool {
  let mustContinue =
    previous2 .>= SIMD16<UInt8>(repeating: .utf8ThreeByteFloor)
    .| previous3 .>= SIMD16<UInt8>(repeating: .utf8FourByteFloor)
  let isContinuation =
    current .>= SIMD16<UInt8>(repeating: .utf8ContinuationFloor)
    .& current .< SIMD16<UInt8>(repeating: .utf8TwoByteFloor)
  let needsContinuation =
    previous1 .>= SIMD16<UInt8>(repeating: .utf8TwoByteFloor) .| mustContinue
  var invalid = isContinuation .^ needsContinuation
  // Leads that exist in no valid sequence: C0, C1 (overlong two byte) and F5 and above.
  invalid .|= (current &- SIMD16<UInt8>(repeating: .utf8TwoByteFloor)) .< SIMD16<UInt8>(repeating: 2)
  invalid .|= current .> SIMD16<UInt8>(repeating: .utf8LeadCeiling)
  // The four second byte constraints: overlong three and four byte forms, encoded surrogates,
  // and scalars past U+10FFFF. Each fires only where the lead is that exact byte, and where the
  // following byte is not a continuation the continuation test above has fired already.
  invalid .|= previous1 .== SIMD16<UInt8>(repeating: .utf8ThreeByteFloor)
    .& current .< SIMD16<UInt8>(repeating: .utf8ThreeByteLowerBound)
  invalid .|= previous1 .== SIMD16<UInt8>(repeating: .utf8SurrogateLead)
    .& current .> SIMD16<UInt8>(repeating: .utf8SurrogateCeiling)
  invalid .|= previous1 .== SIMD16<UInt8>(repeating: .utf8FourByteFloor)
    .& current .< SIMD16<UInt8>(repeating: .utf8FourByteLowerBound)
  invalid .|= previous1 .== SIMD16<UInt8>(repeating: .utf8MaximumLead)
    .& current .> SIMD16<UInt8>(repeating: .utf8MaximumSecond)
  return streamVectorIsNonZero(streamMaskBytes(invalid))
}

// True when `[from, to)` is well formed UTF-8 in full: no sequence may run past `to`, and
// nothing before `from` is part of one. The "previous byte" views are overlapping unaligned
// loads at `i - 1`, `i - 2`, `i - 3`. The first block of a run, a run shorter than a block, and
// a tail shorter than a block go through a 32 byte zero-padded scratch instead: zero reads as
// ASCII, which is what lies before a run (a quote, an escape, a chunk boundary that
// `completePendingUTF8` already settled at a sequence boundary) and what padding after it must
// read as; a tail copies its three real preceding bytes in.
//
// Shimmed and scalar variants are two copies of the same shape rather than one body sharing a
// block-check parameter: the block check is itself `@inline(__always)`, and only a literal
// `Bool` — not a passed-in function value — is guaranteed to fold away entirely at -O, per the
// witness-closure rewrite this codebase already measured and rejected elsewhere.
#if arch(arm64)
  @inlinable
  @inline(__always)
  package func streamValidateUTF8Shimmed(base: UnsafeRawPointer, from: Int, to: Int) -> Bool {
    let count = to &- from
    guard count > 0 else { return true }
    // A sequence cut by the end of the run. The block test sees the lead and never the missing
    // continuation, so the last three bytes are checked against what may legally sit there.
    if base.load(fromByteOffset: to &- 1, as: UInt8.self) >= .utf8TwoByteFloor { return false }
    if count >= 2, base.load(fromByteOffset: to &- 2, as: UInt8.self) >= .utf8ThreeByteFloor {
      return false
    }
    if count >= 3, base.load(fromByteOffset: to &- 3, as: UInt8.self) >= .utf8FourByteFloor {
      return false
    }

    var scratch = SIMD32<UInt8>.zero
    return withUnsafeMutableBytes(of: &scratch) { raw -> Bool in
      let s = raw.baseAddress!
      // Layout: [0, 3) the three bytes before the block, [3, 19) the block, [19, 32) zero.
      let first = Swift.min(count, 16)
      if first == 16 {
        s.storeBytes(
          of: base.loadUnaligned(fromByteOffset: from, as: SIMD16<UInt8>.self),
          toByteOffset: 3, as: SIMD16<UInt8>.self
        )
      } else {
        for j in 0..<first {
          s.storeBytes(
            of: base.load(fromByteOffset: from &+ j, as: UInt8.self),
            toByteOffset: 3 &+ j, as: UInt8.self
          )
        }
      }
      if streamUTF8BlockIsInvalidShimmed(
        current: s.loadUnaligned(fromByteOffset: 3, as: SIMD16<UInt8>.self),
        previous1: s.loadUnaligned(fromByteOffset: 2, as: SIMD16<UInt8>.self),
        previous2: s.loadUnaligned(fromByteOffset: 1, as: SIMD16<UInt8>.self),
        previous3: s.loadUnaligned(fromByteOffset: 0, as: SIMD16<UInt8>.self)
      ) {
        return false
      }

      var i = from &+ 16
      while i &+ 16 <= to {
        if streamUTF8BlockIsInvalidShimmed(
          current: base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self),
          previous1: base.loadUnaligned(fromByteOffset: i &- 1, as: SIMD16<UInt8>.self),
          previous2: base.loadUnaligned(fromByteOffset: i &- 2, as: SIMD16<UInt8>.self),
          previous3: base.loadUnaligned(fromByteOffset: i &- 3, as: SIMD16<UInt8>.self)
        ) {
          return false
        }
        i &+= 16
      }

      if i < to {
        // `i >= from + 16` here, so the three bytes before the tail are the run's own.
        s.storeBytes(of: SIMD16<UInt8>.zero, toByteOffset: 0, as: SIMD16<UInt8>.self)
        s.storeBytes(of: SIMD16<UInt8>.zero, toByteOffset: 16, as: SIMD16<UInt8>.self)
        for j in 0..<3 {
          s.storeBytes(
            of: base.load(fromByteOffset: i &- 3 &+ j, as: UInt8.self),
            toByteOffset: j, as: UInt8.self
          )
        }
        for j in 0..<(to &- i) {
          s.storeBytes(
            of: base.load(fromByteOffset: i &+ j, as: UInt8.self),
            toByteOffset: 3 &+ j, as: UInt8.self
          )
        }
        if streamUTF8BlockIsInvalidShimmed(
          current: s.loadUnaligned(fromByteOffset: 3, as: SIMD16<UInt8>.self),
          previous1: s.loadUnaligned(fromByteOffset: 2, as: SIMD16<UInt8>.self),
          previous2: s.loadUnaligned(fromByteOffset: 1, as: SIMD16<UInt8>.self),
          previous3: s.loadUnaligned(fromByteOffset: 0, as: SIMD16<UInt8>.self)
        ) {
          return false
        }
      }
      return true
    }
  }
#endif
