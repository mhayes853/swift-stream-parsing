import CustomDump
import StreamParsing
import Testing

@Suite
struct `PartialsSequence tests` {
  @Test
  func `Injects Default Commands Into Partial`() throws {
    let defaultCommands: [DefaultStreamParserAction] = [
      .setValue("start"),
      .delegateKeyed(key: "metadata", .setValue(1)),
      .delegateUnkeyed(index: 0, .setValue(true))
    ]

    let byteChunks: [[UInt8]] = [[0x01, 0x02, 0x03]]
    let partials = byteChunks.partials(
      of: MockValue.self,
      from: MockParser(defaultCommands: defaultCommands)
    )

    expectNoDifference(partials.map(\.commands), [defaultCommands])
  }

  @Test
  func `Stops Iteration On Parser Error`() throws {
    let byteChunks: [[UInt8]] = [[0x01, 0x02, 0x03]]
    let partials = byteChunks.partials(of: MockValue.self, from: ThrowingParser())

    expectNoDifference(Array(partials).count, 0)
  }
}

private struct ThrowingParser: StreamParser {
  typealias Action = DefaultStreamParserAction

  mutating func parse(
    bytes: some Sequence<UInt8>,
    into reducer: inout some StreamActionReducer<DefaultStreamParserAction>
  ) throws {
    throw ParserFailure()
  }
}

private struct ParserFailure: Error {}
