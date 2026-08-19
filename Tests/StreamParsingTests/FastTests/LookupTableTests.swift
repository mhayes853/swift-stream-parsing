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
}
