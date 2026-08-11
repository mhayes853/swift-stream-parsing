// Byte scanning primitives.
//
// The parser consumes runs rather than bytes: it finds the next byte needing individual
// attention and hands everything before it to the sink in one piece. Measured against the
// alternatives on arm64, over an 8 KB corpus at varying run lengths (MB/s):
//
//   run length      4       16      64     4096
//   scalar       1401     1480    1528     1548
//   SWAR          940     2373    5730     9817
//   SIMD16       2476     7469   12770    21411
//   SIMD32       1680     2987    9201    18480
//
// SIMD16 wins at every run length, including four bytes. SWAR is worse than scalar below about
// twelve bytes and never beats SIMD16, so it is not used. SIMD32 loses on arm64 because NEON
// registers are 128 bits wide and it lowers to two operations plus a recombine.

@usableFromInline
enum StreamScanner {
  @usableFromInline
  static let vectorWidth = 16

  /// Returns the index of the first byte in `from..<to` that ends a string run: a closing
  /// quote, a backslash, or a control byte.
  @inlinable
  @inline(__always)
  static func stringRunEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
    let quote = SIMD16<UInt8>(repeating: 0x22)
    let backslash = SIMD16<UInt8>(repeating: 0x5C)
    let space = SIMD16<UInt8>(repeating: 0x20)

    var i = from
    while i &+ Self.vectorWidth <= to {
      let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
      let hit = chunk .== quote .| chunk .== backslash .| chunk .< space
      if any(hit) {
        for lane in 0..<Self.vectorWidth where hit[lane] { return i &+ lane }
      }
      i &+= Self.vectorWidth
    }
    while i < to {
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      if byte == 0x22 || byte == 0x5C || byte < 0x20 { return i }
      i &+= 1
    }
    return to
  }

  /// Returns the index of the first non-whitespace byte in `from..<to`.
  @inlinable
  @inline(__always)
  static func whitespaceEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
    var i = from
    while i < to {
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D { return i }
      i &+= 1
    }
    return to
  }

  /// Returns whether any byte in `from..<to` has its high bit set.
  ///
  /// Pure ASCII is the overwhelmingly common case, and it needs no UTF-8 validation at all.
  /// This check rides along with the run scan so the full validator only runs on the rare
  /// non-ASCII run.
  @inlinable
  @inline(__always)
  static func containsNonASCII(base: UnsafeRawPointer, from: Int, to: Int) -> Bool {
    var i = from
    while i &+ Self.vectorWidth <= to {
      let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
      if any(chunk .>= SIMD16<UInt8>(repeating: 0x80)) { return true }
      i &+= Self.vectorWidth
    }
    while i < to {
      if base.load(fromByteOffset: i, as: UInt8.self) >= 0x80 { return true }
      i &+= 1
    }
    return false
  }

  /// Counts newlines in `from..<to`.
  ///
  /// Line and column are only needed to describe an error, so they are reconstructed on demand
  /// rather than tracked per byte. Tracking them in the hot loop measured at roughly half the
  /// per-byte budget for the throughput target.
  @inlinable
  @inline(__always)
  static func newlineCount(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
    var count = 0
    var i = from
    while i < to {
      if base.load(fromByteOffset: i, as: UInt8.self) == 0x0A { count &+= 1 }
      i &+= 1
    }
    return count
  }
}

// MARK: - Key words

extension Span where Element == UInt8 {
  /// The first eight bytes of the span as a little-endian word, zero padded.
  ///
  /// For keys of eight bytes or fewer this is a perfect discriminator: two distinct keys cannot
  /// produce the same padded word, because differing lengths differ in the padding. That is
  /// what lets a generated matcher switch on the word without also checking the length.
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

  /// Whether the span equals `other` byte for byte.
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
