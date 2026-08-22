import Testing

import StreamParsing
import StreamParsingCore

// The kernel answers or declines; it never guesses. So the oracle is the standard library's own
// correctly rounded parser, and the property is exact bit equality on every case the kernel
// accepts. A declined case proves nothing about the kernel and everything about the fallback,
// so declines are counted rather than ignored -- a change that silently started declining
// everything would still pass a "no mismatches" assertion.
//
// Exponent ranges are read from the table's own bounds rather than written as literals, so the
// suite holds whichever extent is built without pretending to cover one that is not there.
@Suite
struct `Eisel-Lemire tests` {
  private struct Outcome {
    var accepted = 0
    var declined = 0
    var mismatches: [String] = []

    mutating func check(magnitude: UInt64, exponent: Int, negative: Bool) {
      let text = "\(negative ? "-" : "")\(magnitude)e\(exponent)"
      guard let value = streamEiselLemire(
        magnitude: magnitude, exponent: exponent, negative: negative
      ) else {
        self.declined += 1
        return
      }
      self.accepted += 1
      let expected = Double(text)!
      if value.bitPattern != expected.bitPattern, self.mismatches.count < 8 {
        self.mismatches.append(
          "\(text): got \(value.bitPattern.hexString) want \(expected.bitPattern.hexString)"
        )
      }
    }
  }

  // A xorshift, so the sweep is identical on every machine and every run: a differential test
  // that samples a different space each time cannot be bisected when it fails.
  private struct Random {
    var state: UInt64 = 0x2026_0821_5EED_1234

    mutating func next() -> UInt64 {
      self.state ^= self.state << 13
      self.state ^= self.state >> 7
      self.state ^= self.state << 17
      return self.state
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
      range.lowerBound + Int(self.next() % UInt64(range.count))
    }
  }

  @Test
  func `Random significands and exponents across the whole table are bit exact`() {
    var outcome = Outcome()
    var random = Random()
    for _ in 0..<200_000 {
      let width = random.next(in: 1...64)
      let magnitude = width == 64 ? random.next() : random.next() & ((1 << UInt64(width)) - 1)
      guard magnitude != 0 else { continue }
      outcome.check(
        magnitude: magnitude,
        exponent: random.next(in: (streamPow10MinExponent + 2)...(streamPow10MaxExponent - 2)),
        negative: random.next() & 1 == 1
      )
    }
    #expect(outcome.mismatches.isEmpty, "\(outcome.mismatches)")
    #expect(outcome.accepted > 150_000)
  }

  // The shape `canada.json` is made of, which is the payload this kernel was written for: 16-19
  // significand digits against a small negative exponent, where the old exact path could not
  // reach and every token built a String instead.
  @Test
  func `Canada shaped significands are bit exact`() {
    var outcome = Outcome()
    var random = Random()
    for _ in 0..<200_000 {
      let digits = random.next(in: 15...19)
      var magnitude: UInt64 = 0
      for _ in 0..<digits { magnitude = magnitude &* 10 &+ UInt64(random.next(in: 0...9)) }
      guard magnitude != 0 else { continue }
      outcome.check(
        magnitude: magnitude,
        exponent: random.next(in: max(-17, streamPow10MinExponent)...0),
        negative: random.next() & 1 == 1
      )
    }
    #expect(outcome.mismatches.isEmpty, "\(outcome.mismatches)")
    #expect(outcome.accepted > 150_000)
  }

  // Subnormals, the overflow boundary, and the powers of two the rounding step turns on.
  @Test
  func `Boundary values are bit exact`() {
    var outcome = Outcome()
    let magnitudes: [UInt64] = [
      1, 2, 5, 9, 10, 99, 1 << 52, (1 << 53) - 1, 1 << 53, (1 << 53) + 1, 1 << 62, 1 << 63,
      UInt64.max, 9_007_199_254_740_993, 1_234_567_890_123_456_789, 999_999_999_999_999_999
    ]
    let table = streamPow10MinExponent...streamPow10MaxExponent
    for exponent in Array(-345...(-290)) + Array(-30...30) + Array(290...312)
    where table.contains(exponent) {
      for magnitude in magnitudes {
        outcome.check(magnitude: magnitude, exponent: exponent, negative: false)
        outcome.check(magnitude: magnitude, exponent: exponent, negative: true)
      }
    }
    #expect(outcome.mismatches.isEmpty, "\(outcome.mismatches)")
  }

  // A zero significand is a signed zero, not a decline: the fallback would allocate a String to
  // reach the same answer.
  @Test
  func `Zero keeps its sign without declining`() {
    #expect(streamEiselLemire(magnitude: 0, exponent: 0, negative: false) == 0.0)
    #expect(
      streamEiselLemire(magnitude: 0, exponent: -5, negative: true)?.sign == .minus
    )
  }

  // Past the table in either direction the kernel declines rather than saturating, so the caller
  // reaches the fallback and the document's own value decides.
  @Test
  func `Exponents outside the table decline`() {
    let above = streamPow10MaxExponent + 1
    let below = streamPow10MinExponent - 1
    #expect(streamEiselLemire(magnitude: 1, exponent: above, negative: false) == nil)
    #expect(streamEiselLemire(magnitude: 1, exponent: below, negative: false) == nil)
  }
}

extension UInt64 {
  fileprivate var hexString: String { "0x" + String(self, radix: 16) }
}
