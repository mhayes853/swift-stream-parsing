// The parser consumes runs rather than bytes: it finds the next byte needing individual
// attention and hands everything before it to the sink in one piece. Measured on arm64 over an
// 8 KB corpus at varying run lengths (MB/s):
//
//   run length      4       16      64     4096
//   scalar       1401     1480    1528     1548
//   SWAR          940     2373    5730     9817
//   SIMD16       2476     7469   12770    21411
//   SIMD32       1680     2987    9201    18480
//
// SIMD16 wins at every run length, including four bytes. SWAR is worse than scalar below about
// twelve bytes and never beats SIMD16, so it is unused. SIMD32 loses on arm64 because NEON
// registers are 128 bits wide and it lowers to two operations plus a recombine.

@usableFromInline
let streamScannerVectorWidth = 16

@inlinable
@inline(__always)
func streamStringRunEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  let quote = SIMD16<UInt8>(repeating: 0x22)
  let backslash = SIMD16<UInt8>(repeating: 0x5C)
  let space = SIMD16<UInt8>(repeating: 0x20)

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
    if byte == 0x22 || byte == 0x5C || byte < 0x20 { return i }
    i &+= 1
  }
  return to
}

@inlinable
@inline(__always)
func streamWhitespaceEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  var i = from
  while i < to {
    let byte = base.load(fromByteOffset: i, as: UInt8.self)
    if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { return i }
    i &+= 1
  }
  return i
}

// Pure ASCII needs no UTF-8 validation at all, so this rides along with the run scan and the
// full validator only runs on the rare non-ASCII run.
@inlinable
@inline(__always)
func streamContainsNonASCII(base: UnsafeRawPointer, from: Int, to: Int) -> Bool {
  let high = SIMD16<UInt8>(repeating: 0x80)
  var i = from
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    if any(chunk .>= high) { return true }
    i &+= streamScannerVectorWidth
  }
  while i < to {
    if base.load(fromByteOffset: i, as: UInt8.self) >= 0x80 { return true }
    i &+= 1
  }
  return false
}

// Line and column exist only to describe an error, so they are reconstructed on demand.
// Tracking them per byte measured at roughly half the per-byte budget for the throughput
// target.
@inlinable
@inline(__always)
func streamNewlineCount(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  var count = 0
  var i = from
  while i < to {
    if base.load(fromByteOffset: i, as: UInt8.self) == 0x0A { count &+= 1 }
    i &+= 1
  }
  return count
}

// MARK: - Key words

extension Span where Element == UInt8 {
  // Zero padding makes this a perfect discriminator for keys of eight bytes or fewer: two
  // distinct keys cannot produce the same word, because a length difference is a padding
  // difference. That is what lets a generated matcher switch on the word alone.
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
