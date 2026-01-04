#if StreamParsingSwiftCollections
  import Collections

  // MARK: - Deque

  extension Deque: StreamParseable where Element: StreamParseable {
    public typealias Partial = Deque<Element.Partial>
  }

  extension Deque: StreamParseableReducer where Element: StreamParseableReducer {
    public static func initialReduceableValue() -> Deque<Element> {
      []
    }
  }

  // MARK: - BitArray

  extension BitArray: StreamParseable {
    public typealias Partial = Self
  }

  extension BitArray: StreamParseableReducer {
    public static func initialReduceableValue() -> BitArray {
      []
    }
  }

  // MARK: - OrderedDictionary

  extension OrderedDictionary: StreamParseable where Key == String, Value: StreamParseable {
    public typealias Partial = OrderedDictionary<String, Value.Partial>
  }

  extension OrderedDictionary: StreamParseableReducer
  where Key == String, Value: StreamParseableReducer {
    public static func initialReduceableValue() -> OrderedDictionary<String, Value> {
      [:]
    }
  }

  // MARK: - TreeDictionary

  extension TreeDictionary: StreamParseable where Key == String, Value: StreamParseable {
    public typealias Partial = TreeDictionary<String, Value.Partial>
  }

  extension TreeDictionary: StreamParseableReducer
  where Key == String, Value: StreamParseableReducer {
    public static func initialReduceableValue() -> TreeDictionary<String, Value> {
      [:]
    }
  }
#endif
