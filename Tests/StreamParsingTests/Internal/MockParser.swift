import StreamParsing

struct MockValue: StreamParseable {
  typealias Partial = MockPartial
}

struct MockPartial: StreamActionReducer {
  var commands = [StreamAction]()

  mutating func reduce(action: StreamAction) throws {
    self.commands.append(action)
  }
}

struct MockParser: StreamParser {
  let defaultCommands: [StreamAction]

  mutating func parse(
    bytes: some Sequence<UInt8>,
    into reducer: inout some StreamActionReducer
  ) throws {
    for byte in bytes {
      try reducer.reduce(action: self.defaultCommands[Int(byte)])
    }
  }
}
