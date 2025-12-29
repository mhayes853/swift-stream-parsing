import CustomDump
import StreamParsing
import Testing

@Suite
struct `PartialsSequence Tests` {
  @Test
  func `Injects Default Commands Into Partial`() throws {
    let defaultCommands: [DefaultStreamAction] = [
      .setValue("start"),
      .delegateKeyed(key: "metadata", .setValue(1)),
      .delegateUnkeyed(index: 0, .setValue(true))
    ]

    let bytes: [[UInt8]] = [[0x00, 0x01, 0x02]]
    let partials = try bytes.partials(
      of: MockValue.self,
      from: MockParser(defaultCommands: defaultCommands)
    )

    expectNoDifference(partials.map(\.commands), [defaultCommands])
  }

  @Test
  func `Injects Default Commands Into Partial From Simple Bytes Sequence`() throws {
    let defaultCommands: [DefaultStreamAction] = [
      .setValue("start"),
      .delegateKeyed(key: "metadata", .setValue(1)),
      .delegateUnkeyed(index: 0, .setValue(true))
    ]

    let bytes: [UInt8] = [0x00, 0x01, 0x02]
    let partials = try bytes.partials(
      of: MockValue.self,
      from: MockParser(defaultCommands: defaultCommands)
    )

    expectNoDifference(
      partials.map(\.commands),
      [[defaultCommands[0]], [defaultCommands[0], defaultCommands[1]], defaultCommands]
    )
  }
}
