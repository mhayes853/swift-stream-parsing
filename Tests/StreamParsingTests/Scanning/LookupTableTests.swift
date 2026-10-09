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
}
