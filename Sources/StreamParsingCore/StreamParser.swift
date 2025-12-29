// MARK: - StreamParser

public protocol StreamParser<StreamAction> {
  associatedtype StreamAction

  mutating func parse(
    bytes: some Sequence<UInt8>,
    into reducer: inout some StreamActionReducer<StreamAction>
  ) throws
}

// MARK: - StreamActionReducer

public protocol StreamActionReducer<StreamAction> {
  associatedtype StreamAction

  mutating func reduce(action: StreamAction) throws
}

// MARK: - StreamParserValue

public indirect enum DefaultStreamAction: Hashable, Sendable {
  case setValue(StreamedValue)
  case delegateUnkeyed(index: Int, Self)
  case delegateKeyed(key: String, Self)
}
