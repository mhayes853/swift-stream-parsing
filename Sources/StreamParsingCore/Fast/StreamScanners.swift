// Short indices and accumulators keep the scanner kernels close to their measured operations.
// swiftlint:disable identifier_name
#if canImport(simd)
  import simd
#endif
import StreamParsingShims

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

@inlinable
@inline(__always)
package func streamVectorContainsNonASCII(_ bytes: SIMD16<UInt8>) -> Bool {
#if canImport(simd)
  simd_reduce_max(bytes) >= .utf8ContinuationFloor
#else
  any(bytes .>= SIMD16<UInt8>(repeating: .utf8ContinuationFloor))
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
  while i &+ streamScannerVectorWidth <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let hit = chunk .== quote .| chunk .== backslash .| chunk .< space
    if any(hit) {
#if canImport(simd)
      let candidates = SIMD16<UInt8>(repeating: 16).replacing(with: lanes, where: hit)
      let lane = Int(simd_reduce_min(candidates))
      let beforeHit = lanes .< SIMD16<UInt8>(repeating: UInt8(lane))
      let prefix = SIMD16<UInt8>.zero.replacing(with: chunk, where: beforeHit)
      return StreamStringRun(
        end: i &+ lane,
        containsNonASCII: streamVectorContainsNonASCII(scanned | prefix)
      )
#else
      for lane in 0..<streamScannerVectorWidth where hit[lane] {
        let beforeHit = lanes .< SIMD16<UInt8>(repeating: UInt8(lane))
        let prefix = SIMD16<UInt8>.zero.replacing(with: chunk, where: beforeHit)
        return StreamStringRun(
          end: i &+ lane,
          containsNonASCII: streamVectorContainsNonASCII(scanned | prefix)
        )
      }
#endif
    }
    scanned |= chunk
    i &+= streamScannerVectorWidth
  }
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

// Unchecked parsing does not consume the UTF-8 observation. Keeping its original end-only kernel
// out of line prevents both SIMD bodies from inflating the validated parser's string loop.
@inlinable
@inline(never)
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

