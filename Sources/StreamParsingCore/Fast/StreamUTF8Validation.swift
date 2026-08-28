// swiftlint:disable identifier_name
#if canImport(simd)
  import simd
#endif
import StreamParsingShims

@inlinable
@inline(__always)
package func streamValidateUTF8Scalar(base: UnsafeRawPointer, from: Int, to: Int) -> Bool {
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
    if streamUTF8BlockIsInvalidPortable(
      current: s.loadUnaligned(fromByteOffset: 3, as: SIMD16<UInt8>.self),
      previous1: s.loadUnaligned(fromByteOffset: 2, as: SIMD16<UInt8>.self),
      previous2: s.loadUnaligned(fromByteOffset: 1, as: SIMD16<UInt8>.self),
      previous3: s.loadUnaligned(fromByteOffset: 0, as: SIMD16<UInt8>.self)
    ) {
      return false
    }

    var i = from &+ 16
    while i &+ 16 <= to {
      if streamUTF8BlockIsInvalidPortable(
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
      if streamUTF8BlockIsInvalidPortable(
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

// The validator the parser calls: table lookups and lane shifts where the platform has them.
@inlinable
@inline(never)
package func streamValidateUTF8(base: UnsafeRawPointer, from: Int, to: Int) -> Bool {
  #if arch(arm64)
    return streamValidateUTF8Shimmed(base: base, from: from, to: to)
  #elseif arch(x86_64)
    // The whole run loop is in the shim, not just the block kernel: `pshufb` and the 32 byte
    // `vpshufb` both need a target attribute Swift cannot spell, and Clang will not inline such
    // a function into a caller that lacks the feature. Since this function is `@inline(never)`
    // and runs once per non-ASCII run, moving the loop across the boundary costs no call that
    // was not already being made. See `StreamParsingShims.h`.
    guard streamHasAVX2 else { return streamValidateUTF8Scalar(base: base, from: from, to: to) }
    return stream_parsing_utf8_validate(base, from, to) != 0
  #else
    return streamValidateUTF8Scalar(base: base, from: from, to: to)
  #endif
}

// The compare-based path, reachable by name so the tests can hold both paths to the same
// oracle on a platform that has the lookup.
@inlinable
@inline(never)
package func streamValidateUTF8Portable(base: UnsafeRawPointer, from: Int, to: Int) -> Bool {
  streamValidateUTF8Scalar(base: base, from: from, to: to)
}


#if arch(x86_64)
// Resolved once, at first use. This is one `movzbl` from a global at every later read -- Swift
// statically initializes it rather than routing through `swift_once`, and it is cheaper than
// calling `stream_parsing_has_avx2()` directly, which inlines that function's own lazy-init test
// into the caller. Confirmed by disassembly, because the opposite was assumed first.
@usableFromInline
let streamHasAVX2: Bool = stream_parsing_has_avx2() != 0
#endif
