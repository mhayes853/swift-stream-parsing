import CustomDump
import StreamParsingCore
import Testing

@Suite
struct `Lookup table tests` {
  @Test
  func `Simple Escape Table Maps Every Byte`() {
    let mappings: [UInt8: UInt8] = [
      0x22: 0x22,
      0x2F: 0x2F,
      0x5C: 0x5C,
      0x62: 0x08,
      0x66: 0x0C,
      0x6E: 0x0A,
      0x72: 0x0D,
      0x74: 0x09
    ]

    let values = UInt8.min...UInt8.max
    let expected = values.map { mappings[$0] }
    let actual = values.map(streamDecodeSimpleEscape)
    expectNoDifference(actual, expected)
  }

  // `sequenceLength` counts thresholds where it used to branch between constants, so the ladder
  // is the oracle and is spelled out here rather than described. Both are asked all 256 bytes:
  // the interesting ones are the continuation bytes, which have no length of their own and which
  // the ladder answered 1 for by falling through its leading `lead < 0x80` arm.
  @Test
  func `Sequence Length Agrees With The Compare Ladder On Every Byte`() {
    func ladder(_ lead: UInt8) -> Int {
      if lead < 0x80 { return 1 }
      if lead >= 0xF0 { return 4 }
      if lead >= 0xE0 { return 3 }
      if lead >= 0xC0 { return 2 }
      return 1
    }

    let values = UInt8.min...UInt8.max
    expectNoDifference(values.map(JSONParser.sequenceLength), values.map(ladder))
  }

  // `streamHexQuad` validates and decodes four digits arithmetically in one register, where a
  // byte at or above 0x80 can carry into its neighbour. Every byte value is tried in every lane,
  // with the other three lanes a valid digit, a lower and an upper case letter, against a
  // per-character oracle.
  @Test
  func `Hex Quad Agrees With A Per Character Decode On Every Byte In Every Lane`() {
    func nibble(_ byte: UInt8) -> UInt32? {
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
      default: nil
      }
    }
    func oracle(_ quad: [UInt8]) -> UInt32? {
      var value: UInt32 = 0
      for byte in quad {
        guard let digit = nibble(byte) else { return nil }
        value = value << 4 | digit
      }
      return value
    }
    let fillers: [[UInt8]] = [Array("7aF0".utf8), Array("Fe9d".utf8), Array("0000".utf8)]
    var mismatches: [String] = []
    for filler in fillers {
      for lane in 0..<4 {
        for byte in UInt8.min...UInt8.max {
          var quad = filler
          quad[lane] = byte
          // Padded on both sides, so the decode reads at an unaligned offset of a larger buffer.
          let padded: [UInt8] = [0x5C, 0x75] + quad + [0x5C, 0x75]
          let actual = padded.withUnsafeBytes { streamHexQuad(base: $0.baseAddress!, from: 2) }
          if actual != oracle(quad) {
            mismatches.append("\(quad): \(String(describing: actual)) vs \(String(describing: oracle(quad)))")
          }
        }
      }
    }
    expectNoDifference(mismatches, [])
  }
}
