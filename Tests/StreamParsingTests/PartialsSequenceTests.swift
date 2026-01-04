// import CustomDump
// import StreamParsing
// import Testing

// @Suite
// struct `PartialsSequence Tests` {
//   @Test
//   func `Injects Default Commands Into Partial`() throws {
//     let defaultCommands: [StreamAction] = [
//       .setValue("start"),
//       .delegateKeyed(key: "metadata", .setValue(1)),
//       .delegateUnkeyed(index: 0, .setValue(true))
//     ]

//     let byteStream: [[UInt8]] = [
//       [0x00, 0x01, 0x02]
//     ]

//     let partials = try byteStream.partials(
//       initialValue: MockPartial(),
//       from: MockParser(defaultCommands: defaultCommands)
//     )

//     expectNoDifference(partials.map(\.commands), [defaultCommands])
//   }

//   @Test
//   func `Injects Default Commands Into Partial For Simple Bytes Sequence`() throws {
//     let defaultCommands: [StreamAction] = [
//       .setValue("start"),
//       .delegateKeyed(key: "metadata", .setValue(1)),
//       .delegateUnkeyed(index: 0, .setValue(true))
//     ]

//     let byteStream: [UInt8] = [0x00, 0x01, 0x02]

//     let partials = try byteStream.partials(
//       initialValue: MockPartial(),
//       from: MockParser(defaultCommands: defaultCommands)
//     )

//     expectNoDifference(
//       partials.map(\.commands),
//       [[defaultCommands[0]], [defaultCommands[0], defaultCommands[1]], defaultCommands]
//     )
//   }

//   @Test
//   func `Skips Emissions When No Reductions Occur For Simple Bytes Sequence`() throws {
//     let defaultCommands: [StreamAction] = [
//       .setValue("start"),
//       .delegateKeyed(key: "metadata", .setValue(1)),
//       .delegateUnkeyed(index: 0, .setValue(true))
//     ]

//     let byteStream: [UInt8] = [0x00, 0x01, 0x02]

//     let partials = try byteStream.partials(
//       initialValue: MockPartial(),
//       from: SelectiveMockParser(
//         defaultCommands: defaultCommands,
//         reducibleBytes: [0x00, 0x02]
//       )
//     )

//     expectNoDifference(
//       partials.map(\.commands),
//       [[defaultCommands[0]], [defaultCommands[0], defaultCommands[2]]]
//     )
//   }
// }
