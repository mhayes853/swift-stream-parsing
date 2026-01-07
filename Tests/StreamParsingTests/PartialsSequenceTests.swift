import CustomDump
import StreamParsing
import Testing

@Suite
struct `PartialsSequence Tests` {
  @Test
  func `Emits Partial For Each Chunked Byte Input`() throws {
    let parser = MockParser<Int>(actions: [0x00: .int(1), 0x01: .int(2), 0x02: .int(3)])
    let byteStream: [[UInt8]] = [[0x00, 0x01, 0x02]]

    let partials = try byteStream.partials(initialValue: 0, from: parser)
    expectNoDifference(partials, [3, 3])
  }

  @Test
  func `Emits Partial For Each Byte`() throws {
    let parser = MockParser<Int>(actions: [0x00: .int(1), 0x01: .int(2), 0x02: .int(3)])
    let byteStream: [UInt8] = [0x00, 0x01, 0x02]

    let partials = try byteStream.partials(initialValue: 0, from: parser)
    expectNoDifference(partials, [1, 2, 3, 3])
  }

  @Test
  func `Emits Same Partial When No Reduction Occurs For Byte`() throws {
    let parser = MockParser<Int>(actions: [0x00: .int(1), 0x02: .int(3)])
    let byteStream: [UInt8] = [0x00, 0x01, 0x02]

    let partials = try byteStream.partials(initialValue: 0, from: parser)
    expectNoDifference(partials, [1, 1, 3, 3])
  }
}
