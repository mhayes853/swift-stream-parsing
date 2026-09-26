// Short indices and accumulators keep the scanner kernels close to their measured operations.
// swiftlint:disable identifier_name
import StreamParsingShims

// MARK: - Whitespace and string runs

// SIMD16 beat scalar, SWAR and SIMD32 at every run length on arm64 (table in NEW_ARCHITECTURE.md):
// NEON registers are 128 bits, so SIMD32 lowers to two operations plus a recombine.

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

// JSON whitespace as a 64-bit set indexed by the byte itself: tab, line feed, carriage return and
// space. Swift's smart shift yields zero on over-shift, which is what makes indexing by a raw byte
// correct (arm64's own shift masks the amount to six bits and would alias byte 64 onto byte 0);
// the defence costs one `cmp`/`ccmp` pair against 63.
@inlinable
package var streamWhitespaceBitmap: UInt64 { 0x0000_0001_0000_2600 }

@inlinable
@inline(__always)
package func streamIsWhitespace(_ byte: UInt8) -> Bool {
  (streamWhitespaceBitmap >> UInt64(byte)) & 1 != 0
}

// The lowest lane where `mask` is set, or 16 when no lane is: the portable spelling of the movemask
// idiom. Mask bytes are 0xFF or 0x00, so read as two little-endian words each lane owns a byte and
// the lane is the trailing zero count over eight; two empty words give 8 + 8 == 16, one past the end.
// Measured: as `low != 0 ? ... : ...` LLVM's X86CmovConverterPass re-branches the `cmov`; keep this.
@inlinable
@inline(__always)
package func streamFirstHitLane(_ mask: SIMDMask<SIMD16<Int8>>) -> Int {
  let words = unsafeBitCast(streamMaskBytes(mask), to: SIMD2<UInt64>.self)
  let lowCount = UInt64(littleEndian: words[0]).trailingZeroBitCount
  let highCount = UInt64(littleEndian: words[1]).trailingZeroBitCount
  let lowEmpty = 0 &- (lowCount &>> 6)
  return (lowCount &>> 3) &+ ((highCount &>> 3) & lowEmpty)
}

#if arch(arm64)
  // The arm64 spelling of the same operation. `stream_parsing_movemask_u8` uses `vshrn_n_u16`,
  // which Swift cannot import directly because its shift is an immediate. Each mask byte becomes
  // one nibble, so the first set lane is the trailing-zero count divided by four. A zero mask's
  // count is 64 and therefore answers 16, matching the portable function.
  @inlinable
  @inline(__always)
  package func streamFirstHitLaneNEON(_ mask: SIMDMask<SIMD16<Int8>>) -> Int {
    stream_parsing_movemask_u8(streamMaskBytes(mask)).trailingZeroBitCount &>> 2
  }
#endif

@inlinable
@inline(__always)
package func streamVectorContainsNonASCII(_ bytes: SIMD16<UInt8>) -> Bool {
  #if arch(arm64)
    return stream_parsing_any_high_u8(bytes) != 0
  #else
    // No horizontal reduction from the Apple-only `simd` module. The high bit of each byte is
    // invariant under the word reinterpretation, and this avoids the out-of-line `SIMD.min` call
    // some standard-library `any(mask)` forms produce.
    let words = unsafeBitCast(bytes, to: SIMD2<UInt64>.self)
    return (words[0] | words[1]) & 0x8080_8080_8080_8080 != 0
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
  // The AVX2 escalation bound, folded into the loop bound so nothing is counted per iteration.
  // Measured: a per-iteration counter cost CITM -2.6% / Qwen -5.0%, and reading `streamHasAVX2`
  // here (a lazy-init accessor call inside an `@inline(__always)` body) cost CITM -9.9% /
  // Twitter -6.1%; keep the availability check behind `@inline(never)`.
#if arch(x86_64)
  let narrowLimit = Swift.min(to, from &+ 2 &* streamScannerVectorWidth)
#else
  let narrowLimit = to
#endif
  while i &+ streamScannerVectorWidth <= narrowLimit {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let hit = chunk .== quote .| chunk .== backslash .| chunk .< space
    // Measured: inlined into `consumeStructuralRun` through the transparent step, the library's
    // `any` on a composed mask loses its specialisation and becomes a `bl` to the generic
    // `SIMD.min` per sixteen bytes. A hit lane is 0xFF, so "any high bit" is the same test.
#if arch(arm64)
    let anyHit = streamVectorContainsNonASCII(streamMaskBytes(hit))
#else
    let anyHit = any(hit)
#endif
    if anyHit {
#if arch(arm64)
      let lane = streamFirstHitLaneNEON(hit)
#else
      let lane = streamFirstHitLane(hit)
#endif
      let beforeHit = lanes .< SIMD16<UInt8>(repeating: UInt8(truncatingIfNeeded: lane))
      let prefix = SIMD16<UInt8>.zero.replacing(with: chunk, where: beforeHit)
      return StreamStringRun(
        end: i &+ lane,
        containsNonASCII: streamVectorContainsNonASCII(scanned | prefix)
      )
    }
    scanned |= chunk
    i &+= streamScannerVectorWidth
  }
#if arch(x86_64)
  // Reaching `narrowLimit` with a full block still ahead means the run survived two blocks without
  // a terminator, which is the only evidence it is long: `to` is the chunk end, not the run end,
  // so no entry-width test could tell a short run from a long one. Everything past this point is
  // behind `@inline(never)`, so this loop's register pressure does not move.
  if i &+ streamScannerVectorWidth <= to {
    return streamStringRunWide(base: base, from: i, to: to, scanned: scanned)
  }
#endif
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

// One compare in front, scans out of line: every JSON whitespace byte is <= 0x20 and every byte that
// may legally follow one is > 0x20. The inlined body must stay this small. Measured: inlining the
// vector body or peeling a one-byte run here cost -18%/-34% on whitespace-free escape-dense
// documents, and routing the byte-fed path (`to &- from == 1`) through the vector cost twitter -20%.
@inlinable
@inline(__always)
package func streamWhitespaceEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  if from < to, base.load(fromByteOffset: from, as: UInt8.self) > .asciiSpace { return from }
  if to &- from < streamScannerVectorWidth {
    return streamWhitespaceScalarEnd(base: base, from: from, to: to)
  }
  return streamWhitespaceRunEnd(base: base, from: from, to: to)
}

// The run end and the byte that ends it, for callers that dispatch on that byte: `streamWhitespaceEnd`
// would load it, test it and throw it away, and every caller would reload the same address.
// The byte is meaningless when `end == to` and is reported as zero there; every caller must test
// that first.
@inlinable
@_transparent
package func streamWhitespaceEndByte(
  base: UnsafeRawPointer, from: Int, to: Int
) -> (end: Int, byte: UInt8) {
  if from < to {
    let byte = base.load(fromByteOffset: from, as: UInt8.self)
    if byte > .asciiSpace { return (from, byte) }
  }
  // Spelled out rather than delegating to `streamWhitespaceEnd`, so the reload below stays on the
  // cold side of the early return rather than becoming a second exit from a shared tail.
  let end =
    to &- from < streamScannerVectorWidth
    ? streamWhitespaceScalarEnd(base: base, from: from, to: to)
    : streamWhitespaceRunEndInline(base: base, from: from, to: to)
  return (end, end < to ? base.load(fromByteOffset: end, as: UInt8.self) : 0)
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

// Which lanes of a block are not whitespace. On arm64 one table lookup and a compare rather than four
// compares ORed: 0x20, 0x09, 0x0A and 0x0D have distinct low nibbles, so a nibble-indexed table hands
// back the one whitespace byte a lane could be. The filler must be 0x00, not 0xFF -- a filler must
// differ from every byte that indexes it, and 0xFF's low nibble matches itself at entry fifteen.
@inlinable
@_transparent
package func streamWhitespaceMissMask(_ chunk: SIMD16<UInt8>) -> SIMDMask<SIMD16<Int8>> {
  #if arch(arm64)
    let table = SIMD16<UInt8>(
      0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x09, 0x0A, 0x00, 0x00, 0x0D, 0x00, 0x00
    )
    return chunk .!= stream_parsing_tbl1q_u8(table, chunk & SIMD16<UInt8>(repeating: 0x0F))
  #else
    let space = SIMD16<UInt8>(repeating: .asciiSpace)
    let tab = SIMD16<UInt8>(repeating: .asciiTab)
    let lineFeed = SIMD16<UInt8>(repeating: .asciiLineFeed)
    let carriageReturn = SIMD16<UInt8>(repeating: .asciiCarriageReturn)
    return .!(chunk .== space .| chunk .== tab .| chunk .== lineFeed .| chunk .== carriageReturn)
  #endif
}

// Kept out of line deliberately: measured, inlining the vector body into the parse loop cost 18-35%
// on whitespace-free escape-dense documents -- the loop's register pressure, not the scan. The
// structural and skip runs take the inline twin below. LOCKSTEP: `streamWhitespaceRunEndInline` is
// this body character for character, and only `StreamScannerTests` exercises this one.
@inlinable
@inline(never)
package func streamWhitespaceRunEnd(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  var i = from
  // Two bytes of bitmap test in front of the vector setup: roughly half of every whitespace-bearing
  // document's runs are one byte. Measured: +6..13% across the corpus with no row regressing, and
  // the bound must stay two written as two straight-line tests -- four cost `citm_catalog` -3.3%,
  // eight -10.0%, and a loop form did not unroll.
  if i < to {
    guard streamIsWhitespace(base.load(fromByteOffset: i, as: UInt8.self)) else { return i }
    i &+= 1
    if i < to {
      guard streamIsWhitespace(base.load(fromByteOffset: i, as: UInt8.self)) else { return i }
      i &+= 1
    }
  }
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let miss = streamWhitespaceMissMask(chunk)
#if arch(arm64)
    if streamVectorContainsNonASCII(streamMaskBytes(miss)) {
      return i &+ streamFirstHitLaneNEON(miss)
    }
#else
    if any(miss) { return i &+ streamFirstHitLane(miss) }
#endif
    i &+= streamScannerVectorWidth
  }
  return streamWhitespaceScalarEnd(base: base, from: i, to: to)
}

// The same body as `streamWhitespaceRunEnd`, forced inline for `consumeStructuralRun`, where the call
// was 16% of `twitter`. LOCKSTEP: a fix to either body belongs in both. Measured: `@_transparent`
// must stay on the whole chain (the step, `streamWhitespaceEndByte`, this) because it inlines before
// the size heuristic votes; the hit test is the shim because `any`/`all` on a composed mask deopts.
@inlinable
@_transparent
package func streamWhitespaceRunEndInline(base: UnsafeRawPointer, from: Int, to: Int) -> Int {
  var i = from
  if i < to {
    guard streamIsWhitespace(base.load(fromByteOffset: i, as: UInt8.self)) else { return i }
    i &+= 1
    if i < to {
      guard streamIsWhitespace(base.load(fromByteOffset: i, as: UInt8.self)) else { return i }
      i &+= 1
    }
  }
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let miss = streamWhitespaceMissMask(chunk)
#if arch(arm64)
    if streamVectorContainsNonASCII(streamMaskBytes(miss)) {
      return i &+ streamFirstHitLaneNEON(miss)
    }
#else
    if any(miss) { return i &+ streamFirstHitLane(miss) }
#endif
    i &+= streamScannerVectorWidth
  }
  return streamWhitespaceScalarEnd(base: base, from: i, to: to)
}


#if arch(x86_64)
// Out of line on purpose, and this is where the availability check belongs: reading `streamHasAVX2`
// is a lazy-init accessor call, affordable once per escalated run and ruinous at the entry of the
// inlined scanner (measured `CITM catalog` -9.9%). Without AVX2 the scan continues at SIMD16 rather
// than failing, which is what the narrow twin below is for.
@inlinable
@inline(never)
package func streamStringRunWide(
  base: UnsafeRawPointer, from: Int, to: Int, scanned: SIMD16<UInt8>
) -> StreamStringRun {
  let soFar = streamVectorContainsNonASCII(scanned)
  if streamHasAVX2 {
    var high: Int32 = 0
    let end = stream_parsing_string_run_avx2(base, from, to, &high)
    return StreamStringRun(end: end, containsNonASCII: soFar || high != 0)
  }
  return streamStringRunNarrow(base: base, from: from, to: to, nonASCIISoFar: soFar)
}

// The SIMD16 continuation, reachable when AVX2 is absent. A second copy of the loop above rather
// than a shared body, for the reason the UTF-8 validator's two variants already document.
@inlinable
@inline(never)
package func streamStringRunNarrow(
  base: UnsafeRawPointer, from: Int, to: Int, nonASCIISoFar: Bool
) -> StreamStringRun {
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
      let lane = streamFirstHitLane(hit)
      let beforeHit = lanes .< SIMD16<UInt8>(repeating: UInt8(truncatingIfNeeded: lane))
      let prefix = SIMD16<UInt8>.zero.replacing(with: chunk, where: beforeHit)
      return StreamStringRun(
        end: i &+ lane,
        containsNonASCII: nonASCIISoFar || streamVectorContainsNonASCII(scanned | prefix)
      )
    }
    scanned |= chunk
    i &+= streamScannerVectorWidth
  }
  var containsNonASCII = nonASCIISoFar || streamVectorContainsNonASCII(scanned)
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
#endif

// MARK: - Key words

// Eight key bytes as one little-endian word -- the first thing a generated matcher does to a key.
// The load must stay bounded by the span: a key span is a borrow into the parser's input and there
// is no padding behind a key to overread into. Under eight bytes it is a halving ladder, not a
// vector: NEON has no masked load, and most JSON keys (`id`, `text`, `user`) land in that tail.
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

// A key's hash, vectored where the length allows it. Two accumulators fed from one SIMD16 load,
// replacing FNV-1a's per-byte multiply chain; the tail is a bounded word ladder for the reason
// `streamPaddedWord` documents. Nothing here is serialised, so the word order only has to agree
// with itself — a key of a given length always takes the same path.
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

// Byte equality, sixteen bytes at a time. The lanes are xored and the difference read as two words
// rather than compared into a mask: `any(mask)` lowers to an out-of-line reduction call, which is
// the same reason `streamIsEightDigits` spells its all-lanes test by hand.
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

// Finds the first byte outside the number token class: the ten numerals, '.', 'e', 'E', '+', '-'.
// The scan is greedy -- placement is the whole-token parse's business -- which keeps it stateless
// and lets one vector test all six conditions per lane. On arm64 that is two nibble-indexed table
// lookups (`ldr, ushr, tbl, and, tbl, cmtst`); trap: on a bitcast mask `all()` silently deoptimises.
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
      // The bound check *is* the terminator test: an all-ones mask has no terminator, its
      // complement is zero, and `trailingZeroBitCount` of zero is 64 — lane 16, one past the block.
      // So `lane` and the branch condition are ready in the same cycle. Measured: testing the mask
      // first leaves `mvn`/`rbit`/`clz` after the branch and a short token pays the chain in full.
      let lane = (~stream_parsing_movemask_u8(hitBytes)).trailingZeroBitCount &>> 2
      if lane < streamScannerVectorWidth { return i &+ lane }
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
      // Measured: a `uminv` reduction here lost (`citm_catalog` +10.5%, nested arrays +11% for the
      // non-reduction form) — its `bsl`/`uminv`/`fmov` chain is dependent latency a short number
      // pays in full. The mask-word form answers out of two general registers, no vector reduction
      // and no per-lane ladder.
      return i &+ streamFirstHitLane(.!hit)
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

// The classic eight-byte conversion as a SIMD lane tree: '0'-biased bytes combine pairwise, the lane
// count halving each stage and widening only where the next place value needs it. Every stage is
// exact, so the block agrees with the scalar loop and only the accumulate below wraps, keeping
// overflowed magnitudes congruent mod 2^64. Measured: 7-13% over the SWAR form it replaced.
@inlinable
@inline(__always)
package func streamParseEightDigits(_ chunk: SIMD8<UInt8>) -> UInt64 {
  streamParseEightDigitValues(chunk &- SIMD8<UInt8>(repeating: .asciiZero))
}

// The same tree over digits that are already biased. The short integer kernel below masks its
// junk lanes to zero before converting, and zero is the digit it wants them to be, so it cannot
// hand this function ASCII.
@inlinable
@inline(__always)
package func streamParseEightDigitValues(_ digits: SIMD8<UInt8>) -> UInt64 {
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

// A direct byte-to-byte map for JSON's eight simple escapes; the parser handles `u` first. Zero means
// "not a simple escape", and no valid one decodes to NUL, so the sentinel needs no validity table.
// A `StaticString` puts the 128 bytes in read-only storage, as the one-allocation path and Embedded need.
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
  var i = from
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    if streamVectorContainsNonASCII(chunk) { return true }
    i &+= streamScannerVectorWidth
  }
  while i < to {
    if base.load(fromByteOffset: i, as: UInt8.self) >= .utf8ContinuationFloor { return true }
    i &+= 1
  }
  return false
}

// MARK: - UTF-8 validation

// Keiser and Lemire's lookup validator ("Validating UTF-8 In Less Than One Instruction Per Byte"):
// every error is visible in two adjacent bytes plus one structural fact, so three nibble-indexed
// error-class tables ANDed and XORed validate a sixteen byte block at once. It answers only valid or
// not; the scalar walk locates the byte, keeping error offsets where `ErrorOffsetTests` pins them.

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
  package func streamUTF8BlockErrorsShimmed(
    current: SIMD16<UInt8>,
    previous1: SIMD16<UInt8>,
    previous2: SIMD16<UInt8>,
    previous3: SIMD16<UInt8>
  ) -> SIMD16<UInt8> {
    stream_parsing_utf8_block_errors(
      current, previous1, previous2, previous3,
      streamUTF8PreviousHighTable, streamUTF8PreviousLowTable, streamUTF8CurrentHighTable
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
  invalid .|= current .> SIMD16<UInt8>(repeating: .utf8MaximumLead)
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

// True when `[from, to)` is well formed UTF-8 in full: no sequence may run past `to` and nothing
// before `from` is part of one. The "previous byte" views are unaligned loads at i-1/2/3; the first
// block, a short run and a short tail go through a 32-byte zero-padded scratch, since zero reads as
// ASCII. Shimmed and scalar are two copies of one shape: only a literal block check folds away at -O.
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
      // Every block ORs into an accumulator and the run pays one reduction at the end: the
      // validator answers only valid or not, so combining the error vectors loses nothing.
      var errors0 = SIMD16<UInt8>.zero
      var errors1 = SIMD16<UInt8>.zero
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
      errors0 |= streamUTF8BlockErrorsShimmed(
        current: s.loadUnaligned(fromByteOffset: 3, as: SIMD16<UInt8>.self),
        previous1: s.loadUnaligned(fromByteOffset: 2, as: SIMD16<UInt8>.self),
        previous2: s.loadUnaligned(fromByteOffset: 1, as: SIMD16<UInt8>.self),
        previous3: s.loadUnaligned(fromByteOffset: 0, as: SIMD16<UInt8>.self)
      )

      var i = from &+ 16
      // Deferring the reduction drops a `dup`/`orr`/`fmov`/`cbnz` per sixteen bytes.
      while i &+ 16 <= to {
        errors0 |= streamUTF8BlockErrorsShimmed(
          current: base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self),
          previous1: base.loadUnaligned(fromByteOffset: i &- 1, as: SIMD16<UInt8>.self),
          previous2: base.loadUnaligned(fromByteOffset: i &- 2, as: SIMD16<UInt8>.self),
          previous3: base.loadUnaligned(fromByteOffset: i &- 3, as: SIMD16<UInt8>.self)
        )
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
        errors1 |= streamUTF8BlockErrorsShimmed(
          current: s.loadUnaligned(fromByteOffset: 3, as: SIMD16<UInt8>.self),
          previous1: s.loadUnaligned(fromByteOffset: 2, as: SIMD16<UInt8>.self),
          previous2: s.loadUnaligned(fromByteOffset: 1, as: SIMD16<UInt8>.self),
          previous3: s.loadUnaligned(fromByteOffset: 0, as: SIMD16<UInt8>.self)
        )
      }
      return !streamVectorIsNonZero(errors0 | errors1)
    }
  }
#endif


// MARK: - Short integer kernel

// An unsigned integer of one to eight numerals, parsed whole with no loop and no data dependent
// branch, or `nil` if the token is not that shape; the class test doubles as the shape test. The load
// is the eight bytes *ending* at the token -- already consumed input, so `end >= 8` makes it safe, and
// right alignment makes the masked-off bytes leading zeros. Mask before bias, or `0x30` borrows in.
@inlinable
@inline(__always)
package func streamShortInteger(base: UnsafeRawPointer, from: Int, end: Int) -> UInt64? {
  let word = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: end &- 8, as: UInt64.self))
  let shift = UInt64(truncatingIfNeeded: 8 &* (8 &- (end &- from)))
  // Masking shift (`&<<`), not the smart one: `shift` is 0...56 but the compiler cannot see that from
  // here and emits the over-shift defence in front of the `and` everything waits on. Measured: removing
  // it is `Canada` +9.7%. The bounds are asserted, not guarded -- hoisting the lower bound into the
  // callers cost `Mesh` -2.8% / `Qwen` -3.3%; `end >= 8` lives in their entry guards.
  assert(end >= 8 && end > from && end &- from <= 8)
  let keep = UInt64.max &<< shift
  let biased = (word & keep) &- (0x3030_3030_3030_3030 & keep)
  let bad = ((biased &+ 0x7676_7676_7676_7676) | biased) & 0x8080_8080_8080_8080
  guard bad == 0 else { return nil }
  var value = (biased &* 2561) >> 8
  value = ((value & 0x00FF_00FF_00FF_00FF) &* 6_553_601) >> 16
  value = ((value & 0x0000_FFFF_0000_FFFF) &* 42_949_672_960_001) >> 32
  return value & 0xFFFF_FFFF
}
