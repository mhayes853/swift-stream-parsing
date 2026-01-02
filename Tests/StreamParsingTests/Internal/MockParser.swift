import StreamParsing

// MARK: - MockValue

struct MockValue: StreamParseable {
  typealias Partial = MockPartial
}

// MARK: - MockPartial

struct MockPartial: StreamParseableReducer {
  var commands = [StreamAction]()

  init() {}

  static func initialReduceableValue() -> Self {
    Self()
  }

  mutating func reduce(action: StreamAction) throws {
    self.commands.append(action)
  }
}

// MARK: - MockParser

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

// MARK: - SelectiveMockParser

struct SelectiveMockParser: StreamParser {
  let defaultCommands: [StreamAction]
  let reducibleBytes: Set<UInt8>

  mutating func parse(
    bytes: some Sequence<UInt8>,
    into reducer: inout some StreamActionReducer
  ) throws {
    for byte in bytes where self.reducibleBytes.contains(byte) {
      try reducer.reduce(action: self.defaultCommands[Int(byte)])
    }
  }
}
