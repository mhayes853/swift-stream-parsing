// MARK: - StreamParsingArrayLikeReducer

protocol StreamParsingArrayLikeReducer: StreamParseableReducer, RangeReplaceableCollection,
  MutableCollection
where Element: StreamParseableReducer {
}

extension StreamParsingArrayLikeReducer {
  public static func initialReduceableValue() -> Self {
    Self()
  }

  public mutating func reduce(action: StreamAction) throws {
    switch action {
    case .delegateUnkeyed(let offset, let nestedAction):
      let index = self.index(self.startIndex, offsetBy: offset)
      var value = self[index]
      try value.reduce(action: nestedAction)
      self[index] = value
    case .createUnkeyedValue:
      self.append(.initialReduceableValue())
    default:
      throw StreamParsingError.unsupportedAction(action)
    }
  }
}

// MARK: - StreamParsingDictionaryLikeReducer

protocol StreamParsingDictionaryLikeReducer: StreamParseableReducer {
  associatedtype Key: Hashable where Key == String
  associatedtype Value: StreamParseableReducer

  init()

  subscript(key: Key) -> Value? { get set }
}

extension StreamParsingDictionaryLikeReducer {
  public static func initialReduceableValue() -> Self {
    Self()
  }

  public mutating func reduce(action: StreamAction) throws {
    switch action {
    case .delegateKeyed(let key, .createKeyedValue):
      self[key] = .initialReduceableValue()
    case .delegateKeyed(let key, let action):
      guard var value = self[key] else { return }
      try value.reduce(action: action)
      self[key] = value
    default:
      throw StreamParsingError.unsupportedAction(action)
    }
  }
}
