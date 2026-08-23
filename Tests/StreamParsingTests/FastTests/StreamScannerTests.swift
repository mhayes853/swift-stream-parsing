import CustomDump
import Testing

import StreamParsingCore

@Suite
struct `Stream scanner tests` {
  // MARK: - Reference implementations

  private static func naiveStringRunEnd(_ bytes: [UInt8], from: Int) -> Int {
    var i = from
    while i < bytes.count {
      let byte = bytes[i]
      if byte == 0x22 || byte == 0x5C || byte < 0x20 { return i }
      i += 1
    }
    return bytes.count
  }

  // The validated variant carries a UTF-8 observation alongside the end, and it is specified as
  // exact: only bytes strictly before the terminator may set it. A byte with the high bit set
  // sitting *after* the closing quote must not reach the caller as `containsNonASCII`, because
  // the parser skips validation on a run whose flag is false.
  private static func naiveStringRun(_ bytes: [UInt8], from: Int, to: Int) -> (Int, Bool) {
    var i = from
    var containsNonASCII = false
    while i < to {
      let byte = bytes[i]
      if byte == 0x22 || byte == 0x5C || byte < 0x20 { return (i, containsNonASCII) }
      containsNonASCII = containsNonASCII || byte >= 0x80
      i += 1
    }
    return (to, containsNonASCII)
  }

  private static func withBase<R>(_ bytes: [UInt8], _ body: (UnsafeRawPointer) -> R) -> R {
    bytes.withUnsafeBytes { body($0.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!) }
  }

  // Wrapping arithmetic is what keeps the block path congruent with this loop past 2^64, so the
  // reference wraps too rather than trapping.
  private static func naiveAccumulate(
    _ bytes: [UInt8], from: Int, to: Int, into magnitude: inout UInt64
  ) -> Int {
    var index = from
    while index < to, bytes[index] &- 0x30 < 10 {
      magnitude = magnitude &* 10 &+ UInt64(bytes[index] &- 0x30)
      index += 1
    }
    return index
  }

  // MARK: - String runs

  // The vectorized path only engages past sixteen bytes and hands the remainder to a scalar
  // tail, so the interesting cases are every length and every start offset around that
  // boundary, not a single large buffer.
  @Test
  func `String run scanning matches a naive scan at every length and offset`() {
    var generator = SystemRandomNumberGenerator()
    for length in 0...80 {
      for _ in 0..<20 {
        var bytes = (0..<length).map { _ in UInt8.random(in: 0x20...0x7E, using: &generator) }
        // Sprinkle terminators so runs end at varied positions rather than only at the end.
        for index in bytes.indices where Int.random(in: 0..<8, using: &generator) == 0 {
          bytes[index] = [0x22, 0x5C, 0x00, 0x1F].randomElement(using: &generator)!
        }
        for from in 0...length {
          let expected = Self.naiveStringRunEnd(bytes, from: from)
          let actual = Self.withBase(bytes) {
            streamStringRun(base: $0, from: from, to: length).end
          }
          expectNoDifference(actual, expected, "length \(length) from \(from)")
        }
      }
    }
  }

  // `streamStringRun` had no direct coverage — only the end-only variant did — which left the
  // UTF-8 observation untested. Non-ASCII is placed both before and after terminators here, so a
  // flag that leaks a byte from past the run fails rather than silently skipping validation.
  @Test
  func `String run scanning reports end and UTF-8 observation at every length and offset`() {
    var generator = SystemRandomNumberGenerator()
    for length in 0...80 {
      for _ in 0..<20 {
        var bytes = (0..<length).map { _ in UInt8.random(in: 0x20...0x7E, using: &generator) }
        for index in bytes.indices where Int.random(in: 0..<8, using: &generator) == 0 {
          bytes[index] = [0x22, 0x5C, 0x00, 0x1F].randomElement(using: &generator)!
        }
        for index in bytes.indices where Int.random(in: 0..<6, using: &generator) == 0 {
          bytes[index] = UInt8.random(in: 0x80...0xFF, using: &generator)
        }
        for from in 0...length {
          let expected = Self.naiveStringRun(bytes, from: from, to: length)
          let actual = Self.withBase(bytes) { streamStringRun(base: $0, from: from, to: length) }
          expectNoDifference(actual.end, expected.0, "end, length \(length) from \(from)")
          expectNoDifference(
            actual.containsNonASCII, expected.1, "flag, length \(length) from \(from)"
          )
        }
      }
    }
  }

  // The exactness case on its own, pinned rather than left to the random sprinkle: ASCII run,
  // terminator, then a high byte. The flag must be false.
  @Test
  func `String run UTF-8 observation ignores bytes past the terminator`() {
    for runLength in [0, 1, 15, 16, 17, 31, 32, 33] {
      var bytes = [UInt8](repeating: 0x61, count: runLength)
      bytes.append(0x22)
      bytes.append(contentsOf: [UInt8](repeating: 0xC3, count: 40))
      let actual = Self.withBase(bytes) { streamStringRun(base: $0, from: 0, to: bytes.count) }
      expectNoDifference(actual.end, runLength, "run length \(runLength)")
      expectNoDifference(actual.containsNonASCII, false, "run length \(runLength)")
    }
  }

  @Test
  func `String run scanning stops at each terminator kind`() {
    for terminator: UInt8 in [0x22, 0x5C, 0x00, 0x1F] {
      var bytes = [UInt8](repeating: 0x61, count: 40)
      bytes[33] = terminator
      let actual = Self.withBase(bytes) {
        streamStringRun(base: $0, from: 0, to: bytes.count).end
      }
      expectNoDifference(actual, 33)
    }
  }

  // MARK: - Whitespace

  @Test
  func `Whitespace scanning skips only JSON whitespace`() {
    let bytes: [UInt8] = [0x20, 0x09, 0x0A, 0x0D, 0x61, 0x20]
    let actual = Self.withBase(bytes) {
      streamWhitespaceEnd(base: $0, from: 0, to: bytes.count)
    }
    expectNoDifference(actual, 4)
  }

  @Test
  func `Whitespace scanning returns the end when everything is whitespace`() {
    let bytes: [UInt8] = [0x20, 0x20, 0x20]
    let actual = Self.withBase(bytes) {
      streamWhitespaceEnd(base: $0, from: 0, to: bytes.count)
    }
    expectNoDifference(actual, 3)
  }

  // The two cases above are both under sixteen bytes, so both take the scalar path and neither
  // ever reaches `streamWhitespaceRunEnd` -- the vector body had no direct coverage at all. These
  // two close that: every byte value is checked at every position of a run long enough to engage
  // the vector path, and lengths and offsets are swept around the block boundary.
  @Test
  func `Whitespace run scanning classifies every byte value correctly at every position`() {
    for testByte in UInt8.min...UInt8.max {
      let isWhitespace = testByte == 0x20 || testByte == 0x09 || testByte == 0x0A || testByte == 0x0D
      for position in 0..<32 {
        var bytes = [UInt8](repeating: 0x20, count: 32)
        bytes[position] = testByte
        let expected = isWhitespace ? 32 : position
        let (guarded, vector) = Self.withBase(bytes) {
          (
            streamWhitespaceEnd(base: $0, from: 0, to: bytes.count),
            streamWhitespaceRunEnd(base: $0, from: 0, to: bytes.count)
          )
        }
        let label = "byte 0x\(String(testByte, radix: 16)) at \(position)"
        expectNoDifference(guarded, expected, label)
        expectNoDifference(vector, expected, label)
      }
    }
  }

  @Test
  func `Whitespace run scanning matches a naive scan at every length and offset`() {
    var generator = SystemRandomNumberGenerator()
    let whitespace: [UInt8] = [0x20, 0x09, 0x0A, 0x0D]
    for length in 0...40 {
      for _ in 0..<20 {
        var bytes = (0..<length).map { _ in whitespace.randomElement(using: &generator)! }
        for index in bytes.indices where Int.random(in: 0..<6, using: &generator) == 0 {
          bytes[index] = UInt8.random(in: 0x21...0xFF, using: &generator)
        }
        for from in 0...length {
          var expected = from
          while expected < length, whitespace.contains(bytes[expected]) { expected += 1 }
          let (guarded, vector) = Self.withBase(bytes) {
            (
              streamWhitespaceEnd(base: $0, from: from, to: length),
              streamWhitespaceRunEnd(base: $0, from: from, to: length)
            )
          }
          expectNoDifference(guarded, expected, "length \(length) from \(from)")
          expectNoDifference(vector, expected, "vector, length \(length) from \(from)")
        }
      }
    }
  }

  // MARK: - ASCII detection

  @Test
  func `Non-ASCII detection matches a naive scan at every length`() {
    for length in 0...40 {
      for position in 0..<max(length, 1) {
        var bytes = [UInt8](repeating: 0x61, count: length)
        if length > 0 { bytes[position] = 0xC3 }
        let expected = bytes.contains { $0 >= 0x80 }
        let actual = Self.withBase(bytes) {
          streamContainsNonASCII(base: $0, from: 0, to: length)
        }
        expectNoDifference(actual, expected, "length \(length) position \(position)")
      }
    }
  }

  @Test
  func `Pure ASCII reports no non-ASCII bytes`() {
    let bytes = [UInt8](repeating: 0x7F, count: 50)
    let actual = Self.withBase(bytes) {
      streamContainsNonASCII(base: $0, from: 0, to: bytes.count)
    }
    expectNoDifference(!actual, true)
  }

  // MARK: - Digit runs

  // The block path only engages past eight bytes and hands the remainder to a scalar tail, so
  // the interesting cases are every length and every start offset around that boundary. Digits
  // dominate the alphabet so runs are long enough to reach the block rather than stopping in
  // the tail every time.
  @Test
  func `Digit accumulation matches a naive scan at every length and offset`() {
    var generator = SystemRandomNumberGenerator()
    for length in 0...40 {
      for _ in 0..<20 {
        var bytes = (0..<length).map { _ in UInt8.random(in: 0x30...0x39, using: &generator) }
        for index in bytes.indices where Int.random(in: 0..<10, using: &generator) == 0 {
          bytes[index] = UInt8.random(in: 0x20...0x2F, using: &generator)
        }
        for from in 0...length {
          var expectedMagnitude: UInt64 = 0
          let expectedEnd = Self.naiveAccumulate(
            bytes, from: from, to: length, into: &expectedMagnitude
          )
          var actualMagnitude: UInt64 = 0
          let actualEnd = Self.withBase(bytes) {
            streamAccumulateDigits(base: $0, from: from, to: length, into: &actualMagnitude)
          }
          expectNoDifference(actualEnd, expectedEnd, "length \(length) from \(from)")
          expectNoDifference(actualMagnitude, expectedMagnitude, "length \(length) from \(from)")
        }
      }
    }
  }

  // A 20+ digit run overflows `UInt64`, and the block and scalar paths only agree there if both
  // wrap. This is the case a document id lands on.
  @Test
  func `Digit accumulation wraps congruently with the scalar loop past the magnitude limit`() {
    for length in 19...40 {
      let bytes = (0..<length).map { UInt8(0x31 + UInt8($0 % 9)) }
      var expectedMagnitude: UInt64 = 0
      let expectedEnd = Self.naiveAccumulate(
        bytes, from: 0, to: length, into: &expectedMagnitude
      )
      var actualMagnitude: UInt64 = 0
      let actualEnd = Self.withBase(bytes) {
        streamAccumulateDigits(base: $0, from: 0, to: length, into: &actualMagnitude)
      }
      expectNoDifference(actualEnd, expectedEnd, "length \(length)")
      expectNoDifference(actualMagnitude, expectedMagnitude, "length \(length)")
    }
  }

  // The accumulator folds into whatever is already there, which is how a fraction's digits
  // continue the integer part's magnitude.
  @Test
  func `Digit accumulation folds into a non-zero starting magnitude`() {
    let bytes = Array("123456789".utf8)
    var magnitude: UInt64 = 42
    let end = Self.withBase(bytes) {
      streamAccumulateDigits(base: $0, from: 0, to: bytes.count, into: &magnitude)
    }
    expectNoDifference(end, 9)
    expectNoDifference(magnitude, 42 * 1_000_000_000 + 123_456_789)
  }

  @Test
  func `Digit accumulation stops at the first non-digit`() {
    let bytes = Array("12345678901234.99".utf8)
    var magnitude: UInt64 = 0
    let end = Self.withBase(bytes) {
      streamAccumulateDigits(base: $0, from: 0, to: bytes.count, into: &magnitude)
    }
    expectNoDifference(end, 14)
    expectNoDifference(magnitude, 12_345_678_901_234)
  }

  // MARK: - Number runs

  private static func isNumberClassByte(_ byte: UInt8) -> Bool {
    byte &- 0x30 < 10 || byte == 0x2E || byte == 0x2B || byte == 0x2D || (byte | 0x20) == 0x65
  }

  // The arm64 path replaces six compares with a two-table nibble lookup, which is table data
  // rather than a direct compare, so every one of the 256 byte values is checked against the
  // compare-chain definition — not just JSON's actual number alphabet — with the byte under
  // test at every lane of a full block, so a table bit that only breaks the vector's edge lanes
  // would still show up. Both `streamNumberRunEnd` and the portable path are checked, so this
  // holds on a machine that only ever runs one of them by dispatch.
  @Test
  func `Number run scanning classifies every byte value correctly at every lane`() {
    for testByte: UInt8 in 0...255 {
      let expected = Self.isNumberClassByte(testByte)
      for position in 0..<16 {
        var bytes = [UInt8](repeating: 0x30, count: 16)
        bytes[position] = testByte
        let expectedEnd = expected ? 16 : position
        let (vector, portable) = Self.withBase(bytes) {
          (
            streamNumberRunEnd(base: $0, from: 0, to: bytes.count),
            streamNumberRunEndPortable(base: $0, from: 0, to: bytes.count)
          )
        }
        expectNoDifference(vector, expectedEnd, "byte 0x\(String(testByte, radix: 16)) at \(position)")
        expectNoDifference(portable, expectedEnd, "byte 0x\(String(testByte, radix: 16)) at \(position)")
      }
    }
  }

  // The vectorized path only engages past sixteen bytes and hands the remainder to a scalar
  // tail, so the interesting cases are every length and every start offset around that boundary.
  @Test
  func `Number run scanning matches a naive scan at every length and offset`() {
    var generator = SystemRandomNumberGenerator()
    for length in 0...40 {
      for _ in 0..<20 {
        var bytes = (0..<length).map { _ in UInt8.random(in: 0x30...0x39, using: &generator) }
        for index in bytes.indices where Int.random(in: 0..<6, using: &generator) == 0 {
          bytes[index] = [0x2E, 0x2B, 0x2D, 0x45, 0x65, 0x20].randomElement(using: &generator)!
        }
        var expected = 0
        while expected < length, Self.isNumberClassByte(bytes[expected]) { expected += 1 }
        let (vector, portable) = Self.withBase(bytes) {
          (
            streamNumberRunEnd(base: $0, from: 0, to: length),
            streamNumberRunEndPortable(base: $0, from: 0, to: length)
          )
        }
        expectNoDifference(vector, expected, "length \(length)")
        expectNoDifference(portable, expected, "length \(length)")
      }
    }
  }
}

@Suite
struct `Key word tests` {
  private static func word(_ key: String) -> UInt64 {
    let bytes = Array(key.utf8)
    return bytes.withUnsafeBufferPointer { Span(_unsafeElements: $0).paddedLeadingWord() }
  }

  @Test
  func `Padded words match hand computed little endian values`() {
    expectNoDifference(Self.word("id"), 0x0000_0000_0000_6469)
    expectNoDifference(Self.word("name"), 0x0000_0000_656D_616E)
    expectNoDifference(Self.word("isActive"), 0x6576_6974_6341_7369)
    expectNoDifference(Self.word(""), 0)
  }

  // Zero padding is what lets a generated matcher switch on the word alone: two distinct keys
  // of eight bytes or fewer cannot collide, because a length difference is a padding
  // difference.
  @Test
  func `Short keys of differing length produce differing words`() {
    expectNoDifference(Self.word("name") != Self.word("names"), true)
    expectNoDifference(Self.word("a") != Self.word("aa"), true)
    expectNoDifference(Self.word("id") != Self.word("di"), true)
  }

  @Test
  func `Long keys share a word only through their first eight bytes`() {
    expectNoDifference(Self.word("descriptionLong"), Self.word("descriptionShort"))
    expectNoDifference(Self.word("descriptionLong"), Self.word("descript"))
  }

  // The wide load and the halving ladder that replaced the byte loop have to agree with it at
  // every length and every offset, including the ones the ladder reaches by a different route:
  // 4+2+1 for seven bytes, 4+1 for five, 2+1 for three. Checked against the byte loop itself
  // rather than against literals, so the property under test is "same answer, fewer loads".
  private static func referenceWord(_ bytes: [UInt8], at start: Int) -> UInt64 {
    var word: UInt64 = 0
    var i = start
    while i < Swift.min(bytes.count, start &+ 8) {
      word |= UInt64(bytes[i]) << ((i &- start) &* 8)
      i &+= 1
    }
    return word
  }

  @Test
  func `Padded words agree with the byte loop at every length and offset`() {
    for count in 0...24 {
      // Distinct, non-zero, and not ascending, so a swapped byte or a wrong shift shows up.
      let bytes = (0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 37) ^ 0xA5 | 1) }
      for start in 0...count {
        let actual = bytes.withUnsafeBufferPointer {
          Span(_unsafeElements: $0).paddedWord(at: start)
        }
        expectNoDifference(actual, Self.referenceWord(bytes, at: start), "count \(count), start \(start)")
      }
    }
  }

  // A span with no padding behind it must still be read within its own bounds. This is the case
  // that stops the wide load from being taken unconditionally, so it is worth its own row: the
  // last byte of the array is the last byte of the span.
  @Test
  func `Reads only within an unpadded span`() {
    var bytes: [UInt8] = [0x61, 0x62, 0x63]
    let word = bytes.withUnsafeMutableBufferPointer {
      Span(_unsafeElements: UnsafeBufferPointer($0)).paddedLeadingWord()
    }
    expectNoDifference(word, 0x0000_0000_0063_6261)
  }
}
