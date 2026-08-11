import Testing

@testable import StreamParsingCore

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

  private static func withBase<R>(_ bytes: [UInt8], _ body: (UnsafeRawPointer) -> R) -> R {
    bytes.withUnsafeBytes { body($0.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!) }
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
            streamStringRunEnd(base: $0, from: from, to: length)
          }
          #expect(actual == expected, "length \(length) from \(from)")
        }
      }
    }
  }

  @Test
  func `String run scanning stops at each terminator kind`() {
    for terminator: UInt8 in [0x22, 0x5C, 0x00, 0x1F] {
      var bytes = [UInt8](repeating: 0x61, count: 40)
      bytes[33] = terminator
      let actual = Self.withBase(bytes) {
        streamStringRunEnd(base: $0, from: 0, to: bytes.count)
      }
      #expect(actual == 33)
    }
  }

  // MARK: - Whitespace

  @Test
  func `Whitespace scanning skips only JSON whitespace`() {
    let bytes: [UInt8] = [0x20, 0x09, 0x0A, 0x0D, 0x61, 0x20]
    let actual = Self.withBase(bytes) {
      streamWhitespaceEnd(base: $0, from: 0, to: bytes.count)
    }
    #expect(actual == 4)
  }

  @Test
  func `Whitespace scanning returns the end when everything is whitespace`() {
    let bytes: [UInt8] = [0x20, 0x20, 0x20]
    let actual = Self.withBase(bytes) {
      streamWhitespaceEnd(base: $0, from: 0, to: bytes.count)
    }
    #expect(actual == 3)
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
        #expect(actual == expected, "length \(length) position \(position)")
      }
    }
  }

  @Test
  func `Pure ASCII reports no non-ASCII bytes`() {
    let bytes = [UInt8](repeating: 0x7F, count: 50)
    let actual = Self.withBase(bytes) {
      streamContainsNonASCII(base: $0, from: 0, to: bytes.count)
    }
    #expect(!actual)
  }

  // MARK: - Newlines

  @Test
  func `Newline counting matches a naive count`() {
    let bytes = Array("a\nbb\n\nccc\n".utf8)
    let actual = Self.withBase(bytes) {
      streamNewlineCount(base: $0, from: 0, to: bytes.count)
    }
    #expect(actual == 4)
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
    #expect(Self.word("id") == 0x0000_0000_0000_6469)
    #expect(Self.word("name") == 0x0000_0000_656D_616E)
    #expect(Self.word("isActive") == 0x6576_6974_6341_7369)
    #expect(Self.word("") == 0)
  }

  // Zero padding is what lets a generated matcher switch on the word alone: two distinct keys
  // of eight bytes or fewer cannot collide, because a length difference is a padding
  // difference.
  @Test
  func `Short keys of differing length produce differing words`() {
    #expect(Self.word("name") != Self.word("names"))
    #expect(Self.word("a") != Self.word("aa"))
    #expect(Self.word("id") != Self.word("di"))
  }

  @Test
  func `Long keys share a word only through their first eight bytes`() {
    #expect(Self.word("descriptionLong") == Self.word("descriptionShort"))
    #expect(Self.word("descriptionLong") == Self.word("descript"))
  }
}
