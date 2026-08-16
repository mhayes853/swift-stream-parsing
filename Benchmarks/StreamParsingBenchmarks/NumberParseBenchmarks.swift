import Benchmark
import StreamParsingCore

// Isolates the number scan-and-parse strategies for the whole-token emission design: the parser
// finds a number token's boundary and produces one NumberInfo at its end, so the boundary scan
// and the digit parse can be organized independently. Each strategy takes a buffer position and
// returns the token end plus the parsed info; the corpora are comma-separated tokens in one
// contiguous buffer with padding after, which is the context a number has inside a document.
//
//   A  fused scalar          today's shape: classify and accumulate in one per-byte loop
//   B  two-pass scalar       contextual boundary scan, then a scalar parse over the token
//   C  two-pass SWAR8        contextual boundary scan, then 8-digit SWAR blocks
//   D  greedy scalar         stateless class scan, then a structured scalar parse
//   E  greedy SIMD16         SIMD16 class scan, then a structured scalar parse
//   F  greedy SIMD16+SWAR8   SIMD16 class scan, then a structured parse with SWAR8 digit runs

// MARK: - Corpora

private struct NumberCorpus {
  var name: String
  var buffer: [UInt8]
  var count: Int
}

private func corpus(_ name: String, _ tokens: [String]) -> NumberCorpus {
  var bytes = [UInt8]()
  for token in tokens {
    bytes.append(contentsOf: token.utf8)
    bytes.append(UInt8(ascii: ","))
  }
  bytes.append(contentsOf: repeatElement(UInt8(ascii: " "), count: 16))
  return NumberCorpus(name: name, buffer: bytes, count: tokens.count)
}

private struct SplitMix: RandomNumberGenerator {
  var state: UInt64
  mutating func next() -> UInt64 {
    self.state &+= 0x9E37_79B9_7F4A_7C15
    var z = self.state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

private func intTokens(digits: ClosedRange<Int>, count: Int, seed: UInt64) -> [String] {
  var generator = SplitMix(state: seed)
  return (0..<count).map { _ in
    let length = Int.random(in: digits, using: &generator)
    var token = String(Int.random(in: 1...9, using: &generator))
    for _ in 1..<length { token += String(Int.random(in: 0...9, using: &generator)) }
    return Bool.random(using: &generator) ? token : "-\(token)"
  }
}

private func decimalTokens(count: Int, seed: UInt64) -> [String] {
  var generator = SplitMix(state: seed)
  return (0..<count).map { _ in
    let whole = Int.random(in: 0...9999, using: &generator)
    let fraction = Int.random(in: 0...99, using: &generator)
    return "\(whole).\(String(format: "%02d", fraction))"
  }
}

private func exponentTokens(count: Int, seed: UInt64) -> [String] {
  var generator = SplitMix(state: seed)
  return (0..<count).map { _ in
    let mantissa = Int.random(in: 1...999, using: &generator)
    let fraction = Int.random(in: 0...9, using: &generator)
    let exponent = Int.random(in: -8...8, using: &generator)
    return "\(mantissa).\(fraction)e\(exponent)"
  }
}

// MARK: - Shared pieces

private let asciiZero = UInt8(ascii: "0")
private let asciiDot = UInt8(ascii: ".")
private let asciiLowerE = UInt8(ascii: "e")
private let asciiUpperE = UInt8(ascii: "E")
private let asciiPlus = UInt8(ascii: "+")
private let asciiDash = UInt8(ascii: "-")

@inline(__always)
private func isNumberByte(_ byte: UInt8) -> Bool {
  byte &- asciiZero < 10 || byte == asciiDot || byte == asciiDash || byte == asciiPlus
    || (byte | 0x20) == asciiLowerE
}

// The classic 8-digit SWAR conversion: bytes are '0'-biased, combined pairwise, then two
// multiplies gather the place values. Wrapping arithmetic keeps it congruent (mod 2^64) with
// the scalar loop.
@inline(__always)
private func parseEightDigits(_ raw: UInt64) -> UInt64 {
  var value = raw &- 0x3030_3030_3030_3030
  value = (value &* 10) &+ (value >> 8)
  let mask: UInt64 = 0x0000_00FF_0000_00FF
  value =
    (((value & mask) &* 0x000F_4240_0000_0064)
    &+ (((value >> 16) & mask) &* 0x0000_2710_0000_0001)) >> 32
  return value & 0xFFFF_FFFF
}

@inline(__always)
private func isEightDigits(_ raw: UInt64) -> Bool {
  ((raw & 0xF0F0_F0F0_F0F0_F0F0)
    | (((raw &+ 0x0606_0606_0606_0606) & 0xF0F0_F0F0_F0F0_F0F0) >> 4))
    == 0x3333_3333_3333_3333
}

@inline(__always)
private func accumulateScalar(
  _ base: UnsafeRawPointer, _ from: Int, _ to: Int, _ magnitude: inout UInt64
) {
  var i = from
  while i < to {
    magnitude = magnitude &* 10 &+ UInt64(base.load(fromByteOffset: i, as: UInt8.self) &- asciiZero)
    i &+= 1
  }
}

@inline(__always)
private func accumulateSWAR(
  _ base: UnsafeRawPointer, _ from: Int, _ to: Int, _ magnitude: inout UInt64
) {
  var i = from
  while i &+ 8 <= to {
    let raw = base.loadUnaligned(fromByteOffset: i, as: UInt64.self)
    magnitude = magnitude &* 100_000_000 &+ parseEightDigits(raw)
    i &+= 8
  }
  accumulateScalar(base, i, to, &magnitude)
}

private struct ParsedNumber: Equatable {
  var end: Int
  var info: NumberInfo
}

@inline(__always)
private func buildInfo(
  magnitude: UInt64,
  totalDigits: Int,
  fractionDigits: Int,
  explicitExponent: Int32,
  exponentNegative: Bool,
  flags: NumberInfo.Flags
) -> NumberInfo {
  var flags = flags
  if totalDigits > 19 { flags.insert(.overflowed) }
  let signed = exponentNegative ? -explicitExponent : explicitExponent
  return NumberInfo(
    magnitude: magnitude,
    exponent: Int16(clamping: Int(signed) - fractionDigits),
    digitCount: UInt16(truncatingIfNeeded: totalDigits),
    flags: flags
  )
}

// MARK: - Strategy A: fused scalar (today's shape)

private func parseFused(_ base: UnsafeRawPointer, _ from: Int, _ to: Int) -> ParsedNumber? {
  var magnitude: UInt64 = 0
  var totalDigits = 0
  var fractionDigits = 0
  var explicitExponent: Int32 = 0
  var flags = NumberInfo.Flags()
  var inExponent = false
  var sawDot = false
  var exponentNegative = false
  var exponentSignSeen = false
  var exponentDigits = 0
  var integerDigits = 0
  var firstIntegerDigitIsZero = false

  var i = from
  while i < to {
    let byte = base.load(fromByteOffset: i, as: UInt8.self)
    let digit = byte &- asciiZero
    if digit < 10 {
      if inExponent {
        exponentDigits &+= 1
        if explicitExponent < 10_000 { explicitExponent = explicitExponent &* 10 &+ Int32(digit) }
      } else {
        magnitude = magnitude &* 10 &+ UInt64(digit)
        totalDigits &+= 1
        if sawDot {
          fractionDigits &+= 1
        } else {
          integerDigits &+= 1
          if integerDigits == 1 { firstIntegerDigitIsZero = digit == 0 }
        }
      }
    } else if byte == asciiDot, !sawDot, !inExponent {
      sawDot = true
      flags.insert(.fraction)
    } else if byte == asciiLowerE || byte == asciiUpperE, !inExponent {
      inExponent = true
      flags.insert(.exponent)
    } else if byte == asciiDash {
      if inExponent, exponentDigits == 0, !exponentSignSeen {
        exponentNegative = true
        exponentSignSeen = true
      } else if totalDigits == 0, !sawDot, !flags.contains(.negative) {
        flags.insert(.negative)
      } else {
        break
      }
    } else if byte == asciiPlus {
      guard inExponent, exponentDigits == 0, !exponentSignSeen else { break }
      exponentSignSeen = true
    } else {
      break
    }
    i &+= 1
  }

  guard integerDigits > 0, integerDigits == 1 || !firstIntegerDigitIsZero,
    !sawDot || fractionDigits > 0, !inExponent || exponentDigits > 0
  else { return nil }
  return ParsedNumber(
    end: i,
    info: buildInfo(
      magnitude: magnitude, totalDigits: totalDigits, fractionDigits: fractionDigits,
      explicitExponent: explicitExponent, exponentNegative: exponentNegative, flags: flags
    )
  )
}

// MARK: - Strategies B/C: contextual boundary scan, deferred parse

@inline(__always)
private func parseTwoPass(
  _ base: UnsafeRawPointer, _ from: Int, _ to: Int, swar: Bool
) -> ParsedNumber? {
  var sawDot = false
  var inExponent = false
  var seenDigit = false
  var seenExponentDigit = false
  var negative = false
  var exponentSignSeen = false

  var i = from
  while i < to {
    let byte = base.load(fromByteOffset: i, as: UInt8.self)
    if byte &- asciiZero < 10 {
      if inExponent { seenExponentDigit = true } else { seenDigit = true }
    } else if byte == asciiDot, !sawDot, !inExponent {
      sawDot = true
    } else if byte == asciiLowerE || byte == asciiUpperE, !inExponent {
      inExponent = true
    } else if byte == asciiDash {
      if inExponent, !seenExponentDigit, !exponentSignSeen {
        exponentSignSeen = true
      } else if !seenDigit, !sawDot, !negative {
        negative = true
      } else {
        break
      }
    } else if byte == asciiPlus {
      guard inExponent, !seenExponentDigit, !exponentSignSeen else { break }
      exponentSignSeen = true
    } else {
      break
    }
    i &+= 1
  }
  return parseSegmented(base, from, i, swar: swar)
}

// MARK: - Strategies D/E/F: greedy class scan, structured parse

@inline(__always)
private func greedyScalarEnd(_ base: UnsafeRawPointer, _ from: Int, _ to: Int) -> Int {
  var i = from
  while i < to, isNumberByte(base.load(fromByteOffset: i, as: UInt8.self)) { i &+= 1 }
  return i
}

@inline(__always)
private func greedySIMDEnd(_ base: UnsafeRawPointer, _ from: Int, _ to: Int) -> Int {
  let zero = SIMD16<UInt8>(repeating: asciiZero)
  let ten = SIMD16<UInt8>(repeating: 10)
  let dot = SIMD16<UInt8>(repeating: asciiDot)
  let lowerE = SIMD16<UInt8>(repeating: asciiLowerE)
  let caseBit = SIMD16<UInt8>(repeating: 0x20)
  let plus = SIMD16<UInt8>(repeating: asciiPlus)
  let dash = SIMD16<UInt8>(repeating: asciiDash)

  var i = from
  while i &+ 16 <= to {
    let chunk = base.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
    let isDigit = (chunk &- zero) .< ten
    let folded = chunk | caseBit
    var hit = isDigit .| chunk .== dot
    hit .|= folded .== lowerE
    hit .|= chunk .== plus
    hit .|= chunk .== dash
    if !all(hit) {
      for lane in 0..<16 where !hit[lane] { return i &+ lane }
    }
    i &+= 16
  }
  return greedyScalarEnd(base, i, to)
}

// Walks the token as sign, integer run, fraction, exponent — the grammar itself — so validation
// falls out of the walk instead of being tracked per byte. Returns nil where the token has bytes
// the grammar has no place for, which is what makes doubled exponent signs impossible rather
// than checked.
@inline(__always)
private func parseSegmented(
  _ base: UnsafeRawPointer, _ from: Int, _ end: Int, swar: Bool
) -> ParsedNumber? {
  var i = from
  var flags = NumberInfo.Flags()
  if i < end, base.load(fromByteOffset: i, as: UInt8.self) == asciiDash {
    flags.insert(.negative)
    i &+= 1
  }

  let integerStart = i
  i = digitRunEnd(base, i, end, swar: swar)
  let integerEnd = i
  let integerDigits = integerEnd - integerStart
  guard integerDigits > 0 else { return nil }
  if integerDigits > 1, base.load(fromByteOffset: integerStart, as: UInt8.self) == asciiZero {
    return nil
  }

  var magnitude: UInt64 = 0
  if swar {
    accumulateSWAR(base, integerStart, integerEnd, &magnitude)
  } else {
    accumulateScalar(base, integerStart, integerEnd, &magnitude)
  }

  var fractionDigits = 0
  if i < end, base.load(fromByteOffset: i, as: UInt8.self) == asciiDot {
    flags.insert(.fraction)
    i &+= 1
    let fractionStart = i
    i = digitRunEnd(base, i, end, swar: swar)
    fractionDigits = i - fractionStart
    guard fractionDigits > 0 else { return nil }
    if swar {
      accumulateSWAR(base, fractionStart, i, &magnitude)
    } else {
      accumulateScalar(base, fractionStart, i, &magnitude)
    }
  }

  var explicitExponent: Int32 = 0
  var exponentNegative = false
  if i < end, (base.load(fromByteOffset: i, as: UInt8.self) | 0x20) == asciiLowerE {
    flags.insert(.exponent)
    i &+= 1
    if i < end {
      let sign = base.load(fromByteOffset: i, as: UInt8.self)
      if sign == asciiDash {
        exponentNegative = true
        i &+= 1
      } else if sign == asciiPlus {
        i &+= 1
      }
    }
    let exponentStart = i
    while i < end {
      let digit = base.load(fromByteOffset: i, as: UInt8.self) &- asciiZero
      guard digit < 10 else { break }
      if explicitExponent < 10_000 { explicitExponent = explicitExponent &* 10 &+ Int32(digit) }
      i &+= 1
    }
    guard i > exponentStart else { return nil }
  }

  // Bytes left before the boundary are class bytes the grammar has no place for.
  guard i == end else { return nil }

  return ParsedNumber(
    end: end,
    info: buildInfo(
      magnitude: magnitude, totalDigits: integerDigits + fractionDigits,
      fractionDigits: fractionDigits, explicitExponent: explicitExponent,
      exponentNegative: exponentNegative, flags: flags
    )
  )
}

@inline(__always)
private func digitRunEnd(_ base: UnsafeRawPointer, _ from: Int, _ to: Int, swar: Bool) -> Int {
  var i = from
  if swar {
    while i &+ 8 <= to, isEightDigits(base.loadUnaligned(fromByteOffset: i, as: UInt64.self)) {
      i &+= 8
    }
  }
  while i < to, base.load(fromByteOffset: i, as: UInt8.self) &- asciiZero < 10 { i &+= 1 }
  return i
}

// MARK: - Registration

private typealias Strategy = (UnsafeRawPointer, Int, Int) -> ParsedNumber?

private func makeStrategies() -> [(String, Strategy)] {
  [
    ("fused scalar", { parseFused($0, $1, $2) }),
    ("two-pass scalar", { parseTwoPass($0, $1, $2, swar: false) }),
    ("two-pass SWAR8", { parseTwoPass($0, $1, $2, swar: true) }),
    ("greedy scalar", { parseSegmented($0, $1, greedyScalarEnd($0, $1, $2), swar: false) }),
    ("greedy SIMD16", { parseSegmented($0, $1, greedySIMDEnd($0, $1, $2), swar: false) }),
    ("greedy SIMD16+SWAR8", { parseSegmented($0, $1, greedySIMDEnd($0, $1, $2), swar: true) }),
  ]
}

private func runStrategy(_ strategy: Strategy, over corpus: NumberCorpus) -> UInt64 {
  corpus.buffer.withUnsafeBufferPointer { buffer in
    let base = UnsafeRawPointer(buffer.baseAddress!)
    let limit = buffer.count - 16
    var checksum: UInt64 = 0
    var i = 0
    var remaining = corpus.count
    while remaining > 0 {
      guard let parsed = strategy(base, i, limit) else {
        preconditionFailure("Corpus token failed to parse")
      }
      checksum = checksum &+ parsed.info.magnitude
        &+ UInt64(bitPattern: Int64(parsed.info.exponent))
      i = parsed.end + 1
      remaining -= 1
    }
    return checksum
  }
}

func numberParseBenchmarks() {
  let strategies = makeStrategies()
  let corpora = [
    corpus("small ints 1-4d", intTokens(digits: 1...4, count: 512, seed: 1)),
    corpus("medium ints 5-10d", intTokens(digits: 5...10, count: 512, seed: 2)),
    corpus("large ints 17-19d", intTokens(digits: 17...19, count: 512, seed: 3)),
    corpus("decimals", decimalTokens(count: 512, seed: 4)),
    corpus("exponents", exponentTokens(count: 512, seed: 5)),
  ]

  // Every strategy must agree on every corpus before any of them is worth timing.
  for corpus in corpora {
    let expected = corpus.buffer.withUnsafeBufferPointer { buffer -> [ParsedNumber] in
      let base = UnsafeRawPointer(buffer.baseAddress!)
      let limit = buffer.count - 16
      var results = [ParsedNumber]()
      var i = 0
      for _ in 0..<corpus.count {
        guard let parsed = parseFused(base, i, limit) else {
          preconditionFailure("Fused failed on \(corpus.name)")
        }
        results.append(parsed)
        i = parsed.end + 1
      }
      return results
    }
    for (name, strategy) in strategies.dropFirst() {
      corpus.buffer.withUnsafeBufferPointer { buffer in
        let base = UnsafeRawPointer(buffer.baseAddress!)
        let limit = buffer.count - 16
        var i = 0
        for parsed in expected {
          guard let actual = strategy(base, i, limit), actual == parsed else {
            preconditionFailure("\(name) disagreed with fused on \(corpus.name)")
          }
          i = actual.end + 1
        }
      }
    }
  }

  for corpus in corpora {
    for (name, strategy) in strategies {
      Benchmark("Numbers \(name) - \(corpus.name)") { benchmark in
        for _ in benchmark.scaledIterations {
          blackHole(runStrategy(strategy, over: corpus))
        }
      }
    }
  }
}
