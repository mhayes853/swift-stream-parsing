#if StreamParsingSwiftCollections
  import Collections

  // MARK: - Deque

  extension Deque: StreamParseable where Element: StreamParseable {
    public typealias Partial = Deque<Element.Partial>

    public var streamPartialValue: Deque<Element.Partial> {
      var deque = Deque<Element.Partial>()
      for element in self {
        deque.append(element.streamPartialValue)
      }
      return deque
    }
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

    public var streamPartialValue: OrderedDictionary<String, Value.Partial> {
      self.mapValues(\.streamPartialValue)
    }
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

    public var streamPartialValue: TreeDictionary<String, Value.Partial> {
      self.mapValues(\.streamPartialValue)
    }
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
