#if StreamParsingSwiftCollections
  import Collections

  // MARK: - Deque

  extension Deque: StreamParseable where Element: StreamParseable {
    public typealias Partial = Deque<Element.Partial>
  }

  extension Deque: StreamParseableValue where Element: StreamParseableValue {
    public static func initialParseableValue() -> Deque<Element> {
      []
    }
  }

  extension Deque: StreamParseableArrayObject where Element: StreamParseableValue {}

  // MARK: - BitArray

  extension BitArray: StreamParseable {
    public typealias Partial = Self
  }

  extension BitArray: StreamParseableValue {
    public static func initialParseableValue() -> BitArray {
      []
    }
  }

  extension BitArray: StreamParseableArrayObject {}

  // MARK: - OrderedDictionary

  extension OrderedDictionary: StreamParseable where Key == String, Value: StreamParseable {
    public typealias Partial = OrderedDictionary<String, Value.Partial>
  }

  extension OrderedDictionary: StreamParseableValue
  where Key == String, Value: StreamParseableValue {
    public static func initialParseableValue() -> OrderedDictionary<String, Value> {
      [:]
    }
  }

  extension OrderedDictionary: StreamParseableDictionaryObject
  where Key == String, Value: StreamParseableValue {}

  // MARK: - TreeDictionary

  extension TreeDictionary: StreamParseable where Key == String, Value: StreamParseable {
    public typealias Partial = TreeDictionary<String, Value.Partial>
  }

  extension TreeDictionary: StreamParseableValue
  where Key == String, Value: StreamParseableValue {
    public static func initialParseableValue() -> TreeDictionary<String, Value> {
      [:]
    }
  }

  extension TreeDictionary: StreamParseableDictionaryObject
  where Key == String, Value: StreamParseableValue {}
#endif
