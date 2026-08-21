// swiftlint:disable identifier_name
#if canImport(simd)
  import simd
#endif
import StreamParsingShims

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

