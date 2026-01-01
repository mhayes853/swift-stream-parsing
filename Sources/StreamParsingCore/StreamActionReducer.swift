// MARK: - StreamActionReducer

public protocol StreamActionReducer {
  mutating func reduce(action: StreamAction) throws
}

// MARK: - StreamParserValue

public indirect enum StreamAction: Hashable, Sendable {
  case setValue(StreamedValue)
  case createUnkeyedValue
  case createKeyedValue
  case delegateUnkeyed(index: Int, Self)
  case delegateKeyed(key: String, Self)
}
