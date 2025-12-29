import CustomDump
import StreamParsing
import Testing

@Suite
struct `AsyncPartialsSequence tests` {
  @Test
  func `Injects Default Commands Into Partial`() async throws {
    let defaultCommands: [DefaultStreamParserAction] = [
      .setValue("start"),
      .delegateKeyed(key: "metadata", .setValue(1)),
      .delegateUnkeyed(index: 0, .setValue(true))
    ]

    let byteStream = AsyncStream<[UInt8]> { continuation in
      continuation.yield([0x01, 0x02, 0x03])
      continuation.finish()
    }

    var partials: [MockPartial] = []
    for try await partial in byteStream.partials(
      of: MockValue.self,
      from: MockParser(defaultCommands: defaultCommands)
    ) {
      partials.append(partial)
    }

    expectNoDifference(partials.map(\.commands), [defaultCommands])
  }
}
