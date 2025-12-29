// MARK: - StreamParser

public protocol StreamParser<Action> {
  associatedtype Action

  mutating func parse(
    bytes: some Sequence<UInt8>,
    into reducer: inout some StreamActionReducer<Action>
  ) throws
}

// MARK: - StreamActionReducer

public protocol StreamActionReducer<Action> {
  associatedtype Action

  mutating func reduce(action: Action) throws
}

// MARK: - StreamParserValue

public indirect enum DefaultStreamParserAction: Hashable, Sendable {
  case setValue(StreamedValue)
  case delegateUnkeyed(index: Int, Self)
  case delegateKeyed(key: String, Self)
}
