#if StreamParsingSwiftCollections
  import Collections

  // MARK: - Deque

  extension Deque: StreamParseable where Element: StreamParseable {
    public typealias Partial = Deque<Element.Partial>
  }

  extension Deque: StreamActionReducer where Element: StreamParseableReducer {}

  extension Deque: StreamParseableReducer where Element: StreamParseableReducer {}

  extension Deque: StreamParsingArrayLikeReducer where Element: StreamParseableReducer {}

  // MARK: - BitArray

  extension BitArray: StreamParseable {
    public typealias Partial = Self
  }

  extension BitArray: StreamActionReducer {}

  extension BitArray: StreamParseableReducer {}

  extension BitArray: StreamParsingArrayLikeReducer {}

  // MARK: - OrderedDictionary

  extension OrderedDictionary: StreamParseable where Key == String, Value: StreamParseable {
    public typealias Partial = OrderedDictionary<String, Value.Partial>
  }

  extension OrderedDictionary: StreamActionReducer
  where Key == String, Value: StreamParseableReducer {}

  extension OrderedDictionary: StreamParseableReducer
  where Key == String, Value: StreamParseableReducer {}

  extension OrderedDictionary: StreamParsingDictionaryLikeReducer
  where Key == String, Value: StreamParseableReducer {}

  // MARK: - TreeDictionary

  extension TreeDictionary: StreamParseable where Key == String, Value: StreamParseable {
    public typealias Partial = TreeDictionary<String, Value.Partial>
  }

  extension TreeDictionary: StreamActionReducer
  where Key == String, Value: StreamParseableReducer {}

  extension TreeDictionary: StreamParseableReducer
  where Key == String, Value: StreamParseableReducer {}

  extension TreeDictionary: StreamParsingDictionaryLikeReducer
  where Key == String, Value: StreamParseableReducer {}
#endif
