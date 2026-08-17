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
    var word: UInt64 = 0
    let end = Swift.min(self.count, start &+ 8)
    var i = start
    while i < end {
      word |= UInt64(self[i]) << ((i &- start) &* 8)
      i &+= 1
    }
    return word
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
