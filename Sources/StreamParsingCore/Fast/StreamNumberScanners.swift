// swiftlint:disable identifier_name
#if canImport(simd)
  import simd
#endif
import StreamParsingShims

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

