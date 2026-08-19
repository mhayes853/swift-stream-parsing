// Short indices and accumulators keep the scanner kernels close to their measured operations.
// swiftlint:disable identifier_name
#if canImport(simd)
  import simd
#endif

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

@inlinable
@inline(__always)
package func streamStringRunEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  let quote = SIMD16<UInt8>(repeating: .asciiQuote)
  let backslash = SIMD16<UInt8>(repeating: .asciiBackslash)
  let space = SIMD16<UInt8>(repeating: .asciiSpace)

  var i = from
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let hit = chunk .== quote .| chunk .== backslash .| chunk .< space
    if any(hit) {
#if canImport(simd)
      let lanes = SIMD16<UInt8>(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
      let candidates = SIMD16<UInt8>(repeating: 16).replacing(with: lanes, where: hit)
      return i &+ Int(simd_reduce_min(candidates))
#else
      for lane in 0..<streamScannerVectorWidth where hit[lane] { return i &+ lane }
#endif
    }
    i &+= streamScannerVectorWidth
  }
  while i < to {
    let byte = base.load(fromByteOffset: i, as: UInt8.self)
    if byte == .asciiQuote || byte == .asciiBackslash || byte < .asciiSpace { return i }
    i &+= 1
  }
  return to
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

// Finds the first byte outside the number token class: digits, '.', 'e', 'E', '+', '-'. The
// scan is greedy — placement is the whole-token parse's business — which is what makes it
// stateless and lets SIMD16 test all six membership conditions per lane. Strategy table in
// NEW_ARCHITECTURE.md: 12.6–23.4 ns/number against 19.5–91.8 for the fused per-byte scan.
@inlinable
@inline(__always)
package func streamNumberRunEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  let zero = SIMD16<UInt8>(repeating: .asciiZero)
  let ten = SIMD16<UInt8>(repeating: 10)
  let dot = SIMD16<UInt8>(repeating: .asciiDot)
  let lowerE = SIMD16<UInt8>(repeating: .asciiLowerE)
  let caseBit = SIMD16<UInt8>(repeating: 0x20)
  let plus = SIMD16<UInt8>(repeating: .asciiPlus)
  let dash = SIMD16<UInt8>(repeating: .asciiDash)

  var i = from
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    var hit = (chunk &- zero) .< ten .| chunk .== dot
    hit .|= (chunk | caseBit) .== lowerE
    hit .|= chunk .== plus
    hit .|= chunk .== dash
    if !all(hit) {
      for lane in 0..<streamScannerVectorWidth where !hit[lane] { return i &+ lane }
    }
    i &+= streamScannerVectorWidth
  }
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
let streamSimpleEscapeTable: StaticString = "\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\"\0\0\0\0\0\0\0\0\0\0\0\0/\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\\\0\0\0\0\0\u{8}\0\0\0\u{c}\0\0\0\0\0\0\0\u{a}\0\0\0\u{d}\0\u{9}\0\0\0\0\0\0\0\0\0\0\0"

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

// Tracking line and column per byte measured at roughly half the per-byte budget, so they are
// reconstructed on demand instead.
@inlinable
@inline(__always)
package func streamNewlineCount(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  var count = 0
  var i = from
  while i < to {
    if base.load(fromByteOffset: i, as: UInt8.self) == .asciiLineFeed { count &+= 1 }
    i &+= 1
  }
  return count
}

// MARK: - Key words

// Eight key bytes as one little-endian word. This is the first thing a generated matcher does to
// every object key in a document, so it is on the hot path of every object heavy parse.
//
// It used to be a byte at a time loop, which is what the sixteen bytes of zero padding behind a
// key span were introduced to make unnecessary: `StreamParsingLayout.keyPaddingByteCount` exists
// so a matcher can load a whole word without a bounds check, and the one function that had the
// guarantee did not take it.
//
// The wide load is bounded by the span rather than by the padding, deliberately. `paddedWord` is
// public on `Span<UInt8>`, so it has to be correct on a span that carries no padding at all;
// reading into the padding would make every caller outside the parser a potential overread for a
// gain the ladder below already collects.
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
