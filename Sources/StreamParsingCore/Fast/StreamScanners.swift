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
      for lane in 0..<streamScannerVectorWidth where hit[lane] { return i &+ lane }
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

@inlinable
@inline(__always)
package func streamWhitespaceEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
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
  let high = SIMD16<UInt8>(repeating: .utf8ContinuationFloor)
  var i = from
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    if any(chunk .>= high) { return true }
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
  // Zero padding makes this a perfect discriminator for keys of eight bytes or fewer, so a
  // generated matcher can switch on the word without also checking the length.
  @inlinable
  @inline(__always)
  public func paddedLeadingWord() -> UInt64 {
    var word: UInt64 = 0
    let limit = Swift.min(self.count, 8)
    var i = 0
    while i < limit {
      word |= UInt64(self[i]) << (i &* 8)
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
