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

// MARK: - Table-driven kernels

extension KernelTraces {
  /// `streamWhitespaceMissMask`, recovered from the shipped kernel rather than copied.
  ///
  /// The kernel's arm64 body is `chunk != table[chunk & 0x0F]`, and the table itself is a literal
  /// inside it. Rather than duplicate that literal here -- a mirror nobody would remember to
  /// update -- the entries are *recovered* by asking the shipped predicate about all 256 bytes: for
  /// low nibble `n`, the entry is the byte with that nibble the kernel calls whitespace, or the
  /// filler when there is none. That also demonstrates the property the filler exists for, since a
  /// filler equal to a byte that indexes it would show up here as a fifth whitespace byte.
  static func whitespaceTable() -> TableTrace {
    var entries = [UInt8](repeating: 0x00, count: 16)
    var recovered: [UInt8] = []
    for byte in UInt8.min...UInt8.max where streamIsWhitespace(byte) {
      entries[Int(byte & 0x0F)] = byte
      recovered.append(byte)
    }

    // A real block from a pretty-printed payload: indentation, then the first structural byte.
    let sample = "\n        \"widget\": {"
    let bytes = Array(sample.utf8)
    let lanes = (0..<16).map { lane -> TableTrace.Lane in
      let byte = lane < bytes.count ? bytes[lane] : 0x20
      return TableTrace.Lane(
        lane: lane,
        byte: byte,
        indices: [Int(byte & 0x0F)],
        values: [entries[Int(byte & 0x0F)]],
        hit: streamIsWhitespace(byte)
      )
    }

    // The recovered table has to reproduce the shipped predicate on every byte, not just on the
    // sixteen the sample happens to contain.
    let verified = (UInt8.min...UInt8.max).allSatisfy { byte in
      (entries[Int(byte & 0x0F)] == byte) == streamIsWhitespace(byte)
    } && recovered.sorted() == [0x09, 0x0A, 0x0D, 0x20]

    return TableTrace(
      kernel: "streamWhitespaceMissMask",
      summary: """
        The four whitespace bytes have distinct low nibbles, so a sixteen entry table indexed by \
        the low nibble hands back the one whitespace byte a lane could be. Comparing the block \
        against that lookup is the whole membership test.
        """,
      replaces: "chunk == 0x20 | chunk == 0x09 | chunk == 0x0A | chunk == 0x0D",
      sample: sample,
      tables: [
        TableTrace.Table(
          name: "low nibble table",
          indexedBy: "byte & 0x0F",
          entries: entries,
          format: "byte",
          bitLabels: [],
          note: """
            The filler is 0x00, not 0xFF. A filler has to differ from every byte that could index \
            it, and 0xFF's low nibble is 0xF -- so at entry fifteen it matched itself, and 0xFF \
            scanned as whitespace until the oracle caught it. 0x00's low nibble is zero, and entry \
            zero already holds the space.
            """
        )
      ],
      lanes: lanes,
      combine: "equal",
      verified: verified
    )
  }

  /// `streamNumberRunEndShimmed`'s membership test: two nibble lookups and `vtstq_u8`.
  static func numberTable() -> TableTrace {
    let high = streamNumberClassHighTable
    let low = streamNumberClassLowTable
    let sample = "-3.14159e+12, \"x\""
    let bytes = Array(sample.utf8)

    let lanes = (0..<16).map { lane -> TableTrace.Lane in
      let byte = lane < bytes.count ? bytes[lane] : 0x20
      let hi = high[Int(byte >> 4)]
      let lo = low[Int(byte & 0x0F)]
      return TableTrace.Lane(
        lane: lane,
        byte: byte,
        indices: [Int(byte >> 4), Int(byte & 0x0F)],
        values: [hi, lo],
        // `vtstq_u8`: the lane is in the number class when the two bitmasks share a set bit.
        hit: hi & lo != 0
      )
    }

    // The run end the shipped scanner reports has to be the first lane the tables miss.
    var padded = bytes
    padded.append(contentsOf: repeatElement(0x20, count: 32))
    let actualEnd = padded.withUnsafeBytes {
      streamNumberRunEnd(base: $0.baseAddress!, from: 0, to: bytes.count)
    }
    let firstMiss = lanes.first(where: { !$0.hit })?.lane ?? 16
    let verified = actualEnd == firstMiss

    return TableTrace(
      kernel: "streamNumberRunEndShimmed",
      summary: """
        A number byte is one of six things -- a digit, `.`, `e`, `E`, `+` or `-`. `tbl` only \
        indexes sixteen entries, so the byte is split: each nibble looks up a bitmask of the \
        classes still possible for it, and `vtstq_u8` asks whether the two share a set bit.
        """,
      replaces: "six compares and their ORs, per lane",
      sample: sample,
      tables: [
        TableTrace.Table(
          name: "high nibble table",
          indexedBy: "byte >> 4",
          entries: (0..<16).map { high[$0] },
          format: "bits",
          bitLabels: ["digit", "dot", "plus", "dash", "e/E"],
          note: "Which classes a byte with this high nibble could belong to."
        ),
        TableTrace.Table(
          name: "low nibble table",
          indexedBy: "byte & 0x0F",
          entries: (0..<16).map { low[$0] },
          format: "bits",
          bitLabels: ["digit", "dot", "plus", "dash", "e/E"],
          note: """
            Low nibble 5 carries both digit and e/E: '5' is 0x35, 'E' is 0x45, 'e' is 0x65. The \
            high nibble decides which -- or neither, since '%' is 0x25 and its high nibble offers \
            none of the bits low nibble 5 does.
            """
        )
      ],
      lanes: lanes,
      combine: "and",
      verified: verified
    )
  }

  /// One block through the UTF-8 validator, with all three lookups and the structural fact.
  static func utf8(sample: String) -> UTF8Trace {
    typealias C = StreamUTF8ErrorClass
    let names: [(UInt8, String)] = [
      (C.tooShort, "too short"), (C.tooLong, "too long"), (C.overlong3, "overlong 3-byte"),
      (C.tooLarge, "too large"), (C.surrogate, "surrogate"), (C.overlong2, "overlong 2-byte"),
      (C.tooLarge1000, "too large / overlong 4-byte"), (C.twoContinuations, "two continuations")
    ]
    let previousHigh = streamUTF8PreviousHighTable
    let previousLow = streamUTF8PreviousLowTable
    let currentHigh = streamUTF8CurrentHighTable

    // Three leading zero bytes, exactly the scratch layout `streamValidateUTF8Scalar` builds, so
    // the shifted views are loads at -1, -2 and -3 rather than anything recomputed here.
    var bytes: [UInt8] = [0, 0, 0] + Array(sample.utf8)
    bytes.append(contentsOf: repeatElement(0x00, count: 32))

    var lanes: [UTF8Trace.Lane] = []
    for lane in 0..<16 {
      let current = bytes[3 + lane]
      let p1 = bytes[2 + lane]
      let p2 = bytes[1 + lane]
      let p3 = bytes[0 + lane]
      let hi = previousHigh[Int(p1 >> 4)]
      let lo = previousLow[Int(p1 & 0x0F)]
      let cur = currentHigh[Int(current >> 4)]
      let special = hi & lo & cur
      // The saturating subtractions the shim spells with `vqsubq_u8`.
      let third = p2 &- Swift.min(p2, 0x60)
      let fourth = p3 &- Swift.min(p3, 0x70)
      let mustContinue = (third | fourth) & 0x80
      let error = special ^ mustContinue
      lanes.append(
        UTF8Trace.Lane(
          lane: lane,
          byte: current,
          previous1: p1,
          previous2: p2,
          previous3: p3,
          indices: [Int(p1 >> 4), Int(p1 & 0x0F), Int(current >> 4)],
          values: [hi, lo, cur],
          special: special,
          mustContinue: mustContinue,
          error: error,
          classes: names.filter { error & $0.0 != 0 }.map(\.1),
          role: role(of: current)
        )
      )
    }

    // The authority: the shipped block test over the same three views.
    let invalid = bytes.withUnsafeBytes { raw -> Bool in
      let base = raw.baseAddress!
      return streamUTF8BlockIsInvalidPortable(
        current: base.loadUnaligned(fromByteOffset: 3, as: SIMD16<UInt8>.self),
        previous1: base.loadUnaligned(fromByteOffset: 2, as: SIMD16<UInt8>.self),
        previous2: base.loadUnaligned(fromByteOffset: 1, as: SIMD16<UInt8>.self),
        previous3: base.loadUnaligned(fromByteOffset: 0, as: SIMD16<UInt8>.self)
      )
    }
    let mirroredInvalid = lanes.contains { $0.error != 0 }

    func table(_ name: String, _ indexedBy: String, _ v: SIMD16<UInt8>, _ note: String)
      -> TableTrace.Table
    {
      TableTrace.Table(
        name: name, indexedBy: indexedBy, entries: (0..<16).map { v[$0] }, format: "bits",
        bitLabels: names.map(\.1), note: note
      )
    }

    return UTF8Trace(
      sample: sample,
      bytes: (0..<16).map { bytes[3 + $0] },
      tables: [
        table(
          "previous high nibble", "previous1 >> 4", previousHigh,
          "What the byte before this lane was: ASCII, a continuation, or a two, three or four byte lead."
        ),
        table(
          "previous low nibble", "previous1 & 0x0F", previousLow,
          "Refines the lead: which overlong forms, surrogates and out-of-range scalars are still possible."
        ),
        table(
          "current high nibble", "current >> 4", currentHigh,
          "What this lane is. Every error is visible in this pair of adjacent bytes -- except one."
        )
      ],
      lanes: lanes,
      valid: !invalid,
      verified: invalid == mirroredInvalid
    )
  }

  private static func role(of byte: UInt8) -> String {
    switch byte {
    case 0x00...0x7F: return "ascii"
    case 0x80...0xBF: return "continuation"
    case 0xC0...0xC1: return "invalid"
    case 0xC2...0xDF: return "lead2"
    case 0xE0...0xEF: return "lead3"
    case 0xF0...0xF4: return "lead4"
    default: return "invalid"
    }
  }

  /// The simple-escape table, read through the shipped decoder.
  static func escapes() -> EscapeTrace {
    let interesting: [(UInt8, String)] = [
      (0x22, #"\""#), (0x5C, #"\\"#), (0x2F, #"\/"#), (0x62, #"\b"#),
      (0x66, #"\f"#), (0x6E, #"\n"#), (0x72, #"\r"#), (0x74, #"\t"#),
      (0x75, #"\u"#), (0x61, #"\a"#), (0x30, #"\0"#)
    ]
    let meanings: [UInt8: String] = [
      0x22: "quotation mark", 0x5C: "reverse solidus", 0x2F: "solidus", 0x08: "backspace",
      0x0C: "form feed", 0x0A: "line feed", 0x0D: "carriage return", 0x09: "tab"
    ]
    var entries: [EscapeTrace.Entry] = []
    for (byte, source) in interesting {
      let decoded = streamDecodeSimpleEscape(byte)
      entries.append(
        EscapeTrace.Entry(
          byte: byte,
          source: source,
          decoded: decoded,
          meaning: decoded.flatMap { meanings[$0] }
            ?? (byte == 0x75
              ? "handled before the table: four more bytes, no one-byte result"
              : "not a simple escape — the zero entry is the sentinel")
        )
      )
    }
    // Exactly eight bytes may decode, and no decode may produce the sentinel.
    let decodable = (UInt8.min...UInt8.max).filter { streamDecodeSimpleEscape($0) != nil }
    let verified =
      decodable.count == 8 && decodable.allSatisfy { streamDecodeSimpleEscape($0) != 0 }
    return EscapeTrace(entries: entries, verified: verified)
  }
}
