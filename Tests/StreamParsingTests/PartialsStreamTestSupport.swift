import StreamParsing

struct MockValue: StreamParseable {
  typealias Partial = MockPartial
}

struct MockPartial: StreamPartial {
  typealias Action = DefaultStreamParserAction

  var commands = [DefaultStreamParserAction]()

  mutating func reduce(action: DefaultStreamParserAction) throws {
    commands.append(action)
  }
}

struct MockParser: StreamParser {
  typealias Action = DefaultStreamParserAction

  let defaultCommands: [DefaultStreamParserAction]

  mutating func parse(
    bytes: some Sequence<UInt8>,
    into reducer: inout some StreamActionReducer<DefaultStreamParserAction>
  ) throws {
    for byte in bytes {
      try reducer.reduce(action: self.defaultCommands[Int(byte)])
    }
  }
}
