// MARK: - StreamActionReducer

public protocol StreamActionReducer {
  mutating func reduce(action: StreamAction) throws
}

// MARK: - StreamParserValue

public indirect enum StreamAction: Hashable, Sendable {
  case setValue(StreamedValue)
  case appendArrayElement(StreamedValue)
  case createObjectValue(StreamedValue)
  case delegateUnkeyed(index: Int, Self)
  case delegateKeyed(key: String, Self)
}
