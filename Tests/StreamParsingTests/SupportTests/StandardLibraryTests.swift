import CustomDump
import StreamParsing
import Testing

@Suite
struct `StandardLibrary tests` {
  @Test
  func `Optional reducer applies parsed value through PartialsStream`() throws {
    let parser = MockSingleValueParser<Int?>(actions: [0x00: .int(42)])
    var stream = PartialsStream(initialValue: nil, from: parser)

    let result = try stream.next(0x00)

    expectNoDifference(result, .some(42))
    expectNoDifference(stream.current, .some(42))
  }

  @Test
  func `Optional reducer applies nil through PartialsStream`() throws {
    let parser = MockSingleValueParser<Int?>(actions: [0x00: .nilValue])
    var stream = PartialsStream(initialValue: .some(1), from: parser)

    let result = try stream.next(0x00)

    expectNoDifference(result, nil)
    expectNoDifference(stream.current, nil)
  }
}
