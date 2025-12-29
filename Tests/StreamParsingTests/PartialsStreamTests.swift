import CustomDump
import StreamParsing
import Testing

@Suite
struct `PartialsStream tests` {
  @Test
  func `Injects Default Commands Into Partial`() throws {
    let defaultCommands: [DefaultStreamParserAction] = [
      .setValue("start"),
      .delegateKeyed(key: "metadata", .setValue(1)),
      .delegateUnkeyed(index: 0, .setValue(true))
    ]

    var stream = PartialsStream(
      of: MockValue.self,
      from: MockParser(defaultCommands: defaultCommands)
    )
    let partial = try stream.next([0x00, 0x01, 0x02])

    expectNoDifference(partial.commands, defaultCommands)
    expectNoDifference(stream.current.commands, defaultCommands)
  }
}
