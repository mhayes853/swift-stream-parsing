// swiftlint:disable identifier_name
import StreamParsingShims

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

// MARK: - Scalar walk and dispatch

@inlinable
@inline(__always)
package func streamValidateUTF8Scalar(base: UnsafeRawPointer, from: Int, to: Int) -> Bool {
  let count = to &- from
  guard count > 0 else { return true }
  // A sequence cut by the end of the run: the block test never sees the missing continuation, so
  // the last three bytes are checked against what may legally sit there.
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

// The validator the parser calls: table lookups and overlapping loads where the platform has
// them (see `StreamParsingShims.h`, where lane shifting was measured 10% slower and dropped).
@inlinable
@inline(never)
package func streamValidateUTF8(base: UnsafeRawPointer, from: Int, to: Int) -> Bool {
  #if arch(arm64)
    return streamValidateUTF8Shimmed(base: base, from: from, to: to)
  #elseif arch(x86_64)
    // The whole run loop is in the shim: `pshufb`/`vpshufb` need a target attribute Swift cannot
    // spell, and Clang will not inline such a function into a caller without it. This function is
    // `@inline(never)` and runs once per non-ASCII run, so the boundary adds no call.
    guard streamHasAVX2 else { return streamValidateUTF8Scalar(base: base, from: from, to: to) }
    return stream_parsing_utf8_validate(base, from, to) != 0
  #else
    return streamValidateUTF8Scalar(base: base, from: from, to: to)
  #endif
}

// The compare-based path by name, so tests hold both paths to one oracle where the lookup exists.
@inlinable
@inline(never)
package func streamValidateUTF8Portable(base: UnsafeRawPointer, from: Int, to: Int) -> Bool {
  streamValidateUTF8Scalar(base: base, from: from, to: to)
}
