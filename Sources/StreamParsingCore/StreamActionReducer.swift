// MARK: - StreamActionReducer

public protocol StreamActionReducer<StreamAction> {
  associatedtype StreamAction = DefaultStreamAction

  mutating func reduce(action: StreamAction) throws
}

// MARK: - StreamParserValue

public indirect enum DefaultStreamAction: Hashable, Sendable {
  case setValue(StreamedValue)
  case delegateUnkeyed(index: Int, Self)
  case delegateKeyed(key: String, Self)
}
