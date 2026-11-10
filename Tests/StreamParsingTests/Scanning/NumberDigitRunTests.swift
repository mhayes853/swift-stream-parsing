import Testing

import StreamParsing
@testable import StreamParsingCore

// `streamAccumulateDigits` finishes a digit run with one eight-byte word instead of a byte loop:
// the word at the run's position when eight bytes remain before the token's end, else the word
// *ending* at the token's end, shifted down. Both find the run's end with one SWAR subtraction
// whose borrows and carries are only harmless above the first non-numeral, and the backward one
// reads bytes before the run. So it is held at two levels against byte-at-a-time oracles:
//
// - the run alone, at every `from`/`to` in short buffers of numerals broken by hostile bytes, in
//   allocations that end exactly at the buffer; and
// - the parser, against an independent transliteration of the grammar walk, with the token at
//   every offset from the chunk start (both sides of the backward load's `to >= 8`), behind
//   earlier tokens, bulk, split at every byte (the carry-over buffer) and byte-fed, where every
//   number and every rejection must come out as the walk reports it.
@Suite
struct `Number digit run tests` {
  // A fixed xorshift, so the sweep is identical on every run and a failure can be bisected.
  private struct Random {
    var state: UInt64 = 0x5EED_2026_1109_000B

    mutating func next() -> UInt64 {
      self.state ^= self.state << 13
      self.state ^= self.state >> 7
      self.state ^= self.state << 17
      return self.state
    }

    mutating func below(_ bound: Int) -> Int { Int(self.next() % UInt64(bound)) }
  }

  // The walk as it stood before the word paths, byte for byte: nil is `.invalidNumber`.
  static func reference(_ token: [UInt8]) -> NumberInfo? {
    var flags = NumberInfo.Flags()
    var i = 0
    let to = token.count
    if i < to, token[i] == 0x2D {
      flags.insert(.negative)
      i += 1
    }
    var magnitude: UInt64 = 0
    let integerStart = i
    while i < to, token[i] &- 0x30 < 10 {
      magnitude = magnitude &* 10 &+ UInt64(token[i] &- 0x30)
      i += 1
    }
    let integerDigits = i - integerStart
    guard integerDigits > 0 else { return nil }
    if integerDigits > 1, token[integerStart] == 0x30 { return nil }
    var fractionDigits = 0
    if i < to, token[i] == 0x2E {
      flags.insert(.fraction)
      i += 1
      let start = i
      while i < to, token[i] &- 0x30 < 10 {
        magnitude = magnitude &* 10 &+ UInt64(token[i] &- 0x30)
        i += 1
      }
      fractionDigits = i - start
      if fractionDigits == 0 { return nil }
    }
    var explicitExponent: Int32 = 0
    var exponentNegative = false
    if i < to, token[i] | 0x20 == 0x65 {
      flags.insert(.exponent)
      i += 1
      if i < to {
        if token[i] == 0x2D {
          exponentNegative = true
          i += 1
        } else if token[i] == 0x2B {
          i += 1
        }
      }
      let start = i
      while i < to, token[i] &- 0x30 < 10 {
        if explicitExponent < 10_000 {
          explicitExponent = explicitExponent * 10 + Int32(token[i] &- 0x30)
        }
        i += 1
      }
      if i == start { return nil }
    }
    if i != to { return nil }
    let total = integerDigits + fractionDigits
    if total > 19 { flags.insert(.overflowed) }
    let exponent = exponentNegative ? -explicitExponent : explicitExponent
    return NumberInfo(
      magnitude: magnitude,
      exponent: Int16(clamping: Int(exponent) - fractionDigits),
      digitCount: UInt16(clamping: total),
      flags: flags
    )
  }

  private static let digits = Array("0123456789".utf8)
  private static let numberClass = Array("0123456789-+.eE".utf8)
  private static let junk: [UInt8] = Array(0x20...0x7E) + [0x0A, 0x09, 0x0D, 0x00, 0x80, 0xFF]

  // A well-formed token most of the time, then mutated at random: a byte replaced, inserted or
  // dropped, from the number class.
  private static func token(_ random: inout Random) -> [UInt8] {
    var out: [UInt8] = []
    if random.below(2) == 0 { out.append(0x2D) }
    let integer = random.below(5) == 0 ? random.below(21) + 1 : random.below(4) + 1
    for k in 0..<integer {
      out.append(k == 0 && integer > 1 ? digits[random.below(9) + 1] : digits[random.below(10)])
    }
    if random.below(4) != 0 {
      out.append(0x2E)
      let fraction = random.below(4) == 0 ? random.below(22) + 1 : random.below(16) + 1
      for _ in 0..<fraction { out.append(digits[random.below(10)]) }
    }
    if random.below(10) == 0 {
      out.append(random.below(2) == 0 ? 0x65 : 0x45)
      if random.below(2) == 0 { out.append(random.below(2) == 0 ? 0x2D : 0x2B) }
      for _ in 0..<random.below(4) { out.append(digits[random.below(10)]) }
    }
    if random.below(4) == 0 {
      let at = random.below(out.count + 1)
      switch random.below(3) {
      case 0 where at < out.count: out[at] = numberClass[random.below(numberClass.count)]
      case 1: out.insert(numberClass[random.below(numberClass.count)], at: at)
      default: if at < out.count, out.count > 1 { out.remove(at: at) }
      }
    }
    if random.below(16) == 0, out.count > 1, random.below(2) == 0 { out[0] = 0x30 }
    return out
  }

  // MARK: The digit run

  // The digit run of `bytes[from..<to]`, one numeral at a time.
  private static func referenceRun(
    _ bytes: [UInt8], from: Int, to: Int, magnitude: UInt64
  ) -> [UInt64] {
    var i = from
    var magnitude = magnitude
    while i < to, bytes[i] &- 0x30 < 10 {
      magnitude = magnitude &* 10 &+ UInt64(bytes[i] &- 0x30)
      i += 1
    }
    return [UInt64(i), magnitude]
  }

  // `streamAccumulateDigits` over an allocation of exactly `bytes.count`, so a load past either
  // end reads outside the allocation (ASan names it; a plain run may not).
  private static func run(
    _ bytes: [UInt8], from: Int, to: Int, magnitude: UInt64
  ) -> [UInt64] {
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Swift.max(bytes.count, 1), alignment: 1)
    defer { raw.deallocate() }
    raw.copyMemory(from: bytes, byteCount: bytes.count)
    var magnitude = magnitude
    let end = streamAccumulateDigits(base: raw, from: from, to: to, into: &magnitude)
    return [UInt64(end), magnitude]
  }

  // Every `from`/`to` pair, so the forward partial word, the backward word (and the shift that
  // drops the bytes before `from`), the full blocks and the byte loop below eight bytes each meet
  // every run length, terminator and prefix.
  @Test
  func `The digit run agrees with the byte walk at every extent`() {
    var random = Random()
    for _ in 0..<4_000 {
      let count = random.below(28) + 1
      let bytes = (0..<count).map { _ in
        random.below(5) == 0
          ? Self.junk[random.below(Self.junk.count)] : Self.digits[random.below(10)]
      }
      let magnitude = random.below(3) == 0 ? random.next() : UInt64(random.below(1000))
      for from in 0...count {
        for to in from...count {
          let got = Self.run(bytes, from: from, to: to, magnitude: magnitude)
          let want = Self.referenceRun(bytes, from: from, to: to, magnitude: magnitude)
          if got != want {
            Issue.record("\(bytes) [\(from), \(to)): got \(got) want \(want)")
            return
          }
        }
      }
    }
  }

  // Long runs: the wrapping accumulate across blocks and the final word past nineteen digits,
  // where the magnitude is only congruent mod 2^64.
  @Test
  func `Long runs wrap exactly as the byte walk does`() {
    var random = Random()
    for count in 1...48 {
      for _ in 0..<50 {
        let bytes = (0..<count).map { _ in Self.digits[random.below(10)] } + [0x2E, 0x35]
        for to in [count, count + 1, count + 2] {
          #expect(
            Self.run(bytes, from: 0, to: to, magnitude: 7)
              == Self.referenceRun(bytes, from: 0, to: to, magnitude: 7)
          )
        }
      }
    }
  }

  // Every byte value as the terminator after every partial length, so the first non-numeral is
  // found under a borrow (below `'0'`) or a carry (at or above `0x8A`) from each possible byte.
  @Test
  func `Every byte value ends the run where the byte walk does`() {
    for terminator in UInt8.min...UInt8.max {
      for length in 0...7 {
        let bytes =
          Array("[1.5,".utf8) + [UInt8](repeating: 0x39, count: length) + [terminator]
          + Array("0099".utf8)
        let from = 5
        for to in (from + length)...bytes.count {
          #expect(
            Self.run(bytes, from: from, to: to, magnitude: 1)
              == Self.referenceRun(bytes, from: from, to: to, magnitude: 1),
            "0x\(String(terminator, radix: 16)) after \(length)"
          )
        }
      }
    }
  }

  // MARK: Through the parser

  private enum Outcome: Equatable {
    case numbers([NumberInfo])
    case failed(JSONParsingError.Reason, Int)
  }

  // `[` + spaces + earlier members + token + `]`, so the token's chunk offset sweeps both sides
  // of `to >= 8`. Offsets come back relative to the token.
  private static func outcome(
    _ token: [UInt8], before: [UInt8], pad: Int, split: Int? = nil, byByte: Bool = false
  ) -> Outcome {
    let head = [0x5B] + [UInt8](repeating: 0x20, count: pad) + before
    let bytes = head + token + [0x5D]
    var sink = InfoSink()
    do {
      if byByte {
        try feedByByte(bytes, into: &sink)
      } else if let split {
        try feed(bytes, splitAt: split, into: &sink)
      } else {
        try feed(bytes, into: &sink)
      }
    } catch {
      return .failed(error.reason, error.byteOffset - head.count)
    }
    return .numbers(sink.infos)
  }

  private static let befores: [[UInt8]] = [
    [], Array("1.5,".utf8), Array("12.125, ".utf8), Array("\"a.b.c.d.e.f\",".utf8),
    Array("-7,".utf8), Array("{\"k\":0.5},".utf8),
  ]

  @Test
  func `The parser reports what the walk reports at every offset`() {
    var random = Random()
    for round in 0..<6_000 {
      let token = Self.token(&random)
      guard !token.isEmpty else { continue }
      let before = Self.befores[round % Self.befores.count]
      var expected: Outcome?
      for pad in 0..<34 {
        let got = Self.outcome(token, before: before, pad: pad)
        if let expected {
          #expect(got == expected, "\(String(decoding: token, as: UTF8.self)) pad \(pad)")
          if got != expected { return }
        } else {
          expected = got
        }
      }
      // The value itself, when the walk accepts the token.
      if let info = Self.reference(token), case .numbers(let infos)? = expected {
        #expect(infos.last == info, "\(String(decoding: token, as: UTF8.self))")
      }
    }
  }

  @Test
  func `Corpus shapes agree bulk, split at every byte and byte-fed`() {
    var random = Random()
    for _ in 0..<300 {
      var token = Self.token(&random)
      if token.isEmpty { token = [0x31] }
      let before = Array("[0.25,-1.5,1234567890,\"x.y\",".utf8)
      let bulk = Self.outcome(token, before: before, pad: 20)
      let total = 1 + 20 + before.count + token.count + 1
      for split in 1..<total {
        let got = Self.outcome(token, before: before, pad: 20, split: split)
        #expect(got == bulk, "\(String(decoding: token, as: UTF8.self)) split \(split)")
        if got != bulk { return }
      }
      #expect(Self.outcome(token, before: before, pad: 20, byByte: true) == bulk)
      if let info = Self.reference(token), case .numbers(let infos) = bulk {
        #expect(infos.last == info, "\(String(decoding: token, as: UTF8.self))")
      }
    }
  }
}

private struct InfoSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  var infos: [NumberInfo] = []

  mutating func beginObject() -> StreamContainerDisposition { .stream }
  mutating func endObject() {}
  mutating func beginArray() -> StreamContainerDisposition { .stream }
  mutating func endArray() {}
  mutating func key(_ bytes: Span<UInt8>) {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) { self.infos.append(info) }
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}
