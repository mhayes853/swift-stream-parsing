import Foundation
import StreamParsingCore

// ASCII constants are spelled as literals here rather than reused from `UInt8+ASCIIConstants`:
// those are `@usableFromInline`, which is internal to `StreamParsingCore`, and `package` is the
// widest access this target can see across the module boundary.
private let quoteByte: UInt8 = 0x22
private let backslashByte: UInt8 = 0x5C
private let spaceByte: UInt8 = 0x20

enum KernelTraces {
  // MARK: - String run

  /// Mirrors `streamStringRun` block by block and checks the mirror against the real call.
  static func stringRun(sample: String) -> StringRunTrace {
    var bytes = Array(sample.utf8)
    // The kernel reads whole 16-byte blocks, so the sample owns a tail of slack it never reports
    // on; `to` stays at the real length.
    let count = bytes.count
    bytes.append(contentsOf: repeatElement(0x20, count: 32))

    var blocks: [StringRunTrace.Block] = []
    var tail: [StringRunTrace.TailStep] = []
    var end = count
    var containsNonASCII = false

    bytes.withUnsafeBytes { raw in
      let base = raw.baseAddress!
      var scanned = SIMD16<UInt8>.zero
      var i = 0
      var finished = false

      // The one-byte peel at the top of the kernel: a terminator in lane 0 never reaches a vector.
      if count > 0 {
        let first = bytes[0]
        if first == quoteByte || first == backslashByte || first < spaceByte {
          end = 0
          finished = true
        }
      }

      let width = 16
      while !finished, i + width <= count {
        let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
        let isQuote = chunk .== SIMD16<UInt8>(repeating: quoteByte)
        let isBackslash = chunk .== SIMD16<UInt8>(repeating: backslashByte)
        let isControl = chunk .< SIMD16<UInt8>(repeating: spaceByte)
        let hit = isQuote .| isBackslash .| isControl
        let lane = streamFirstHitLane(hit)
        let anyHit = lane < width

        var scannedAfter = scanned
        if anyHit {
          // The prefix mask: only the bytes *before* the terminator contribute to the non-ASCII
          // answer, which is what makes the flag exact rather than conservative.
          let lanes = SIMD16<UInt8>(0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)
          let beforeHit = lanes .< SIMD16<UInt8>(repeating: UInt8(truncatingIfNeeded: lane))
          scannedAfter = scanned | SIMD16<UInt8>.zero.replacing(with: chunk, where: beforeHit)
        } else {
          scannedAfter = scanned | chunk
        }

        blocks.append(
          StringRunTrace.Block(
            offset: i,
            bytes: (0..<width).map { chunk[$0] },
            isQuote: (0..<width).map { isQuote[$0] },
            isBackslash: (0..<width).map { isBackslash[$0] },
            isControl: (0..<width).map { isControl[$0] },
            hit: (0..<width).map { hit[$0] },
            anyHit: anyHit,
            hitLane: lane,
            scannedAfter: (0..<width).map { scannedAfter[$0] },
            nonASCIIAfter: streamVectorContainsNonASCII(scannedAfter)
          )
        )

        scanned = scannedAfter
        if anyHit {
          end = i + lane
          containsNonASCII = streamVectorContainsNonASCII(scanned)
          finished = true
          break
        }
        i += width
      }

      if !finished {
        containsNonASCII = streamVectorContainsNonASCII(scanned)
        while i < count {
          let byte = bytes[i]
          let terminates = byte == quoteByte || byte == backslashByte || byte < spaceByte
          tail.append(StringRunTrace.TailStep(offset: i, byte: byte, terminates: terminates))
          if terminates { break }
          containsNonASCII = containsNonASCII || byte >= 0x80
          i += 1
        }
        end = tail.last?.terminates == true ? tail.last!.offset : count
      }
    }

    // The authority. If the mirror above ever stops agreeing with the shipped kernel, the bundle
    // says so instead of animating the mirror's answer as if it were the parser's.
    let actual = bytes.withUnsafeBytes { raw in
      streamStringRun(base: raw.baseAddress!, from: 0, to: count)
    }
    return StringRunTrace(
      sample: sample,
      bytes: Array(bytes[0..<count]),
      blocks: blocks,
      tail: tail,
      end: actual.end,
      containsNonASCII: actual.containsNonASCII,
      verified: actual.end == end && actual.containsNonASCII == containsNonASCII
    )
  }

  // MARK: - Whitespace

  /// Records real `streamWhitespaceEnd` calls at the positions the parser makes them.
  ///
  /// The call sites are derived, not parsed: the scan runs immediately after every structural byte
  /// and at the start of the chunk, which is the whole of its contract. Every recorded `end` is
  /// the shipped function's answer.
  static func whitespace(sample: String) -> WhitespaceTrace {
    let bytes = Array(sample.utf8)
    let structural: Set<UInt8> = [0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A]
    var sites = [0]
    for (i, b) in bytes.enumerated() where structural.contains(b) { sites.append(i + 1) }

    var calls: [WhitespaceTrace.Call] = []
    bytes.withUnsafeBytes { raw in
      let base = raw.baseAddress!
      for from in sites where from < bytes.count {
        let to = bytes.count
        let end = streamWhitespaceEnd(base: base, from: from, to: to)
        let firstByte = bytes[from]
        let earlyOut = firstByte > spaceByte
        let path = earlyOut ? "early" : (to - from < 16 ? "scalar" : "vector")
        calls.append(
          WhitespaceTrace.Call(
            from: from,
            to: to,
            firstByte: firstByte,
            earlyOut: earlyOut,
            path: path,
            end: end,
            runLength: end - from,
            // Only the window the scan could actually look at, classified with the shipped
            // predicate rather than a reimplemented one.
            lanes: earlyOut
              ? []
              : (from..<min(from + 16, to)).map {
                WhitespaceTrace.Lane(offset: $0, byte: bytes[$0], isWhitespace: streamIsWhitespace(bytes[$0]))
              }
          )
        )
      }
    }
    return WhitespaceTrace(sample: sample, bytes: bytes, calls: calls)
  }

  // MARK: - Numbers

  static func numbers(_ samples: [String]) -> NumberTrace {
    // Hostile padding, exactly as `ShortIntegerKernelTests` does it: the mask-before-bias defect
    // borrows out of bytes below `'0'`, and spaces would hide it.
    let prefix = "\n,\"}]\t:{"
    var cases: [NumberTrace.Case] = []

    for sample in samples {
      var bytes = Array(prefix.utf8) + Array(sample.utf8)
      let from = prefix.utf8.count
      let limit = bytes.count
      bytes.append(contentsOf: repeatElement(0x20, count: 32))

      let runEnd = bytes.withUnsafeBytes {
        streamNumberRunEnd(base: $0.baseAddress!, from: from, to: limit)
      }
      let digitCount = runEnd - from
      var steps: [NumberTrace.SWARStep] = []
      var value: UInt64?
      var accepted = false
      var verified = true

      if digitCount >= 1 && digitCount <= 8 && runEnd >= 8 {
        let actual = bytes.withUnsafeBytes {
          streamShortInteger(base: $0.baseAddress!, from: from, end: runEnd)
        }
        // Mirror of the kernel, purely so the intermediates can be shown.
        let word = bytes.withUnsafeBytes {
          UInt64(littleEndian: $0.baseAddress!.loadUnaligned(fromByteOffset: runEnd - 8, as: UInt64.self))
        }
        let shift = UInt64(truncatingIfNeeded: 8 * (8 - digitCount))
        let keep = UInt64.max << shift
        let biased = (word & keep) &- (0x3030_3030_3030_3030 & keep)
        let bad = ((biased &+ 0x7676_7676_7676_7676) | biased) & 0x8080_8080_8080_8080
        var v = (biased &* 2561) >> 8
        let stage1 = v
        v = ((v & 0x00FF_00FF_00FF_00FF) &* 6_553_601) >> 16
        let stage2 = v
        v = ((v & 0x0000_FFFF_0000_FFFF) &* 42_949_672_960_001) >> 32
        let mirrored: UInt64? = bad == 0 ? v & 0xFFFF_FFFF : nil

        steps = [
          step("load", "Eight bytes ending at the token, not starting at it — the read is behind the cursor, so one `end >= 8` test makes it safe.", word),
          step("mask", "`UInt64.max << \(shift)` keeps the \(digitCount) token bytes and zeroes the junk below them. Right alignment is also what removes the scaling step.", keep),
          step("masked", "The junk prefix is gone. Masking comes *before* the bias: a byte below `'0'` would borrow into the leading digit.", word & keep),
          step("bias", "Subtract `'0'` from every kept lane.", biased),
          step("validate", "Nonzero means some lane was not a digit. The digit test doubles as the shape test.", bad),
          step("tree 1", "×2561 >> 8 folds pairs of digits into bytes.", stage1),
          step("tree 2", "×6553601 >> 16 folds pairs of bytes into 16-bit groups.", stage2),
          step("tree 3", "×42949672960001 >> 32 folds the halves; the low 32 bits are the value.", v)
        ]
        value = actual
        accepted = actual != nil
        verified = actual == mirrored
      }

      cases.append(
        NumberTrace.Case(
          text: sample,
          prefix: prefix,
          runEnd: digitCount,
          digitCount: digitCount,
          acceptedByShortInteger: accepted,
          value: value,
          steps: steps,
          verified: verified
        )
      )
    }
    return NumberTrace(cases: cases)
  }

  private static func step(_ label: String, _ detail: String, _ word: UInt64) -> NumberTrace.SWARStep {
    NumberTrace.SWARStep(
      label: label,
      detail: detail,
      hex: String(format: "%016llX", word),
      // Little-endian storage order, which is the order the bytes sit in memory and therefore the
      // order the token's digits appear in.
      bytes: (0..<8).map { UInt8(truncatingIfNeeded: word >> (8 * UInt64($0))) }
    )
  }
}
