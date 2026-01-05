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

    public static func registerHandlers(
      in handlers: inout some StreamParserHandlers<Self>
    ) {
      handlers.registerArrayHandler(\.self)
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

    public static func registerHandlers(
      in handlers: inout some StreamParserHandlers<Self>
    ) {
      handlers.registerArrayHandler(\.self)
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

    public static func registerHandlers<Handlers: StreamParserHandlers<Self>>(
      in handlers: inout Handlers
    ) {}
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

    public static func registerHandlers<Handlers: StreamParserHandlers<Self>>(
      in handlers: inout Handlers
    ) {}
  }
#endif
