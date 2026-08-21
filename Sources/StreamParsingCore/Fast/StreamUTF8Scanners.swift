// swiftlint:disable identifier_name
#if canImport(simd)
  import simd
#endif
import StreamParsingShims

// MARK: - Lane shifts

// `previous`'s last `count` lanes followed by `current`'s first `16 - count`: the view of "the
// byte `count` back" for every lane of `current`, given the block before it. On arm64 this is
// one `ext` through the shim; the portable form does the same thing on the two 64-bit halves —
// shift each half up by `8 * count` bits and OR in the bits that crossed from the half below,
// which for the low half is the top of `previous` — so it never leaves vector registers and
// never touches memory. Little-endian lane order, which every supported target has. `count` is
// a literal at every call site, so the switch folds.
@inlinable
@inline(__always)
package func streamBytesShiftedIn(
  from previous: SIMD16<UInt8>, into current: SIMD16<UInt8>, count: Int
) -> SIMD16<UInt8> {
  #if arch(arm64)
    return streamBytesShiftedInShimmed(from: previous, into: current, count: count)
  #else
    return streamBytesShiftedInPortable(from: previous, into: current, count: count)
  #endif
}

#if arch(arm64)
  @inlinable
  @inline(__always)
  package func streamBytesShiftedInShimmed(
    from previous: SIMD16<UInt8>, into current: SIMD16<UInt8>, count: Int
  ) -> SIMD16<UInt8> {
    switch count {
    case 1: return stream_parsing_extq_u8_1(previous, current)
    case 2: return stream_parsing_extq_u8_2(previous, current)
    default: return stream_parsing_extq_u8_3(previous, current)
    }
  }
#endif

@inlinable
@inline(__always)
package func streamBytesShiftedInPortable(
  from previous: SIMD16<UInt8>, into current: SIMD16<UInt8>, count: Int
) -> SIMD16<UInt8> {
  let bits = UInt64(truncatingIfNeeded: count &* 8)
  let currentWords = unsafeBitCast(current, to: SIMD2<UInt64>.self)
  let previousWords = unsafeBitCast(previous, to: SIMD2<UInt64>.self)
  let shifted = currentWords &<< bits
  let carried = SIMD2<UInt64>(previousWords[1], currentWords[0]) &>> (64 &- bits)
  return unsafeBitCast(shifted | carried, to: SIMD16<UInt8>.self)
}

// MARK: - UTF-8 validation

// Keiser and Lemire's lookup validator ("Validating UTF-8 In Less Than One Instruction Per
// Byte"). Every UTF-8 error is visible in a window of two adjacent bytes plus one structural
// fact — a continuation is required after a three or four byte lead — so a sixteen byte block
// is validated at once: the high nibble of the previous byte, its low nibble and the high
// nibble of the current byte each index a table of error classes, the three results are ANDed,
// and the structural fact is XORed in. The "previous byte" views come from the block before,
// carried across the loop and lane shifted in. On arm64 the three lookups are `tbl` and the
// three shifts are `ext`, through the `StreamParsingShims` wrappers; everywhere else the same
// classes are recomputed with range compares and the shifts are 64-bit arithmetic, which is
// more instructions and still none of the scalar walk's per-sequence branches.
//
// It answers only valid or not: an invalid run is rare, and the parser's scalar walk then finds
// the byte and reports it, which keeps every error offset exactly where `ErrorOffsetTests` pins
// it. `completePendingUTF8` is untouched — a sequence split by a chunk is reassembled and
// checked there, before any run is scanned.

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
  package func streamUTF8BlockIsInvalidShimmed(
    current: SIMD16<UInt8>,
    previous1: SIMD16<UInt8>,
    previous2: SIMD16<UInt8>,
    previous3: SIMD16<UInt8>
  ) -> Bool {
    streamVectorIsNonZero(
      stream_parsing_utf8_block_errors(
        current, previous1, previous2, previous3,
        streamUTF8PreviousHighTable, streamUTF8PreviousLowTable, streamUTF8CurrentHighTable
      )
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
  invalid .|= current .> SIMD16<UInt8>(repeating: .utf8LeadCeiling)
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

// True when `[from, to)` is well formed UTF-8 in full: no sequence may run past `to`, and
// nothing before `from` is part of one. The "previous byte" views are overlapping unaligned
// loads at `i - 1`, `i - 2`, `i - 3`. The first block of a run, a run shorter than a block, and
// a tail shorter than a block go through a 32 byte zero-padded scratch instead: zero reads as
// ASCII, which is what lies before a run (a quote, an escape, a chunk boundary that
// `completePendingUTF8` already settled at a sequence boundary) and what padding after it must
// read as; a tail copies its three real preceding bytes in.
//
// Shimmed and scalar variants are two copies of the same shape rather than one body sharing a
// block-check parameter: the block check is itself `@inline(__always)`, and only a literal
// `Bool` — not a passed-in function value — is guaranteed to fold away entirely at -O, per the
// witness-closure rewrite this codebase already measured and rejected elsewhere.
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
      if streamUTF8BlockIsInvalidShimmed(
        current: s.loadUnaligned(fromByteOffset: 3, as: SIMD16<UInt8>.self),
        previous1: s.loadUnaligned(fromByteOffset: 2, as: SIMD16<UInt8>.self),
        previous2: s.loadUnaligned(fromByteOffset: 1, as: SIMD16<UInt8>.self),
        previous3: s.loadUnaligned(fromByteOffset: 0, as: SIMD16<UInt8>.self)
      ) {
        return false
      }

      var i = from &+ 16
      while i &+ 16 <= to {
        if streamUTF8BlockIsInvalidShimmed(
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
        if streamUTF8BlockIsInvalidShimmed(
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
#endif
