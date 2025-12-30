import StreamParsing

struct MockValue: StreamParseable {
  typealias Partial = MockPartial
}

struct MockPartial: StreamActionReducer {
  typealias StreamAction = DefaultStreamAction

  var commands = [DefaultStreamAction]()

  mutating func reduce(action: DefaultStreamAction) throws {
    self.commands.append(action)
  }
}

struct MockParser: StreamParser {
  typealias StreamAction = DefaultStreamAction

  let defaultCommands: [DefaultStreamAction]

  mutating func parse(
    bytes: some Sequence<UInt8>,
    into reducer: inout some StreamActionReducer<DefaultStreamAction>
  ) throws {
    for byte in bytes {
      try reducer.reduce(action: self.defaultCommands[Int(byte)])
    }
  }
}
