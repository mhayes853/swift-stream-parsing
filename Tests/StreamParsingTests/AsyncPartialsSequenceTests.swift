// import CustomDump
// import StreamParsing
// import Testing

// @Suite
// struct `AsyncPartialsSequence Tests` {
//   @Test
//   func `Injects Default Commands Into Partial`() async throws {
//     let defaultCommands: [StreamAction] = [
//       .setValue("start"),
//       .delegateKeyed(key: "metadata", .setValue(1)),
//       .delegateUnkeyed(index: 0, .setValue(true))
//     ]

//     let byteStream = AsyncStream<[UInt8]> { continuation in
//       continuation.yield([0x00, 0x01, 0x02])
//       continuation.finish()
//     }

//     var partials: [MockPartial] = []
//     let stream = byteStream.partials(
//       initialValue: MockPartial(),
//       from: MockParser(defaultCommands: defaultCommands)
//     )
//     for try await partial in stream {
//       partials.append(partial)
//     }

//     expectNoDifference(partials.map(\.commands), [defaultCommands])
//   }

//   @Test
//   func `Injects Default Commands Into Partial For Simple Bytes Sequence`() async throws {
//     let defaultCommands: [StreamAction] = [
//       .setValue("start"),
//       .delegateKeyed(key: "metadata", .setValue(1)),
//       .delegateUnkeyed(index: 0, .setValue(true))
//     ]

//     let byteStream = AsyncStream<UInt8> { continuation in
//       continuation.yield(0x00)
//       continuation.yield(0x01)
//       continuation.yield(0x02)
//       continuation.finish()
//     }

//     var partials = [MockPartial]()
//     let stream = byteStream.partials(
//       initialValue: MockPartial(),
//       from: MockParser(defaultCommands: defaultCommands)
//     )
//     for try await partial in stream {
//       partials.append(partial)
//     }

//     expectNoDifference(
//       partials.map(\.commands),
//       [[defaultCommands[0]], [defaultCommands[0], defaultCommands[1]], defaultCommands]
//     )
//   }

//   @Test
//   func `Skips Emissions When No Reductions Occur For Simple Bytes Sequence`() async throws {
//     let defaultCommands: [StreamAction] = [
//       .setValue("start"),
//       .delegateKeyed(key: "metadata", .setValue(1)),
//       .delegateUnkeyed(index: 0, .setValue(true))
//     ]

//     let byteStream = AsyncStream<UInt8> { continuation in
//       continuation.yield(0x00)
//       continuation.yield(0x01)
//       continuation.yield(0x02)
//       continuation.finish()
//     }

//     var partials = [MockPartial]()
//     let stream = byteStream.partials(
//       initialValue: MockPartial(),
//       from: SelectiveMockParser(
//         defaultCommands: defaultCommands,
//         reducibleBytes: [0x00, 0x02]
//       )
//     )
//     for try await partial in stream {
//       partials.append(partial)
//     }

//     expectNoDifference(
//       partials.map(\.commands),
//       [[defaultCommands[0]], [defaultCommands[0], defaultCommands[2]]]
//     )
//   }
// }
