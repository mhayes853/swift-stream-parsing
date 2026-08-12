#if StreamParsingSwiftCollections
  import OrderedCollections
  import HashTreeCollections
  import DequeModule
  import BitCollections

  // MARK: - Conversion protocols

  // These are destinations to convert into, not members to parse into. The schema generator
  // reads a member's shape from syntax, so only `[T]` and `[String: T]` route as containers;
  // everything here is marked unroutable so a member declared with one warns at expansion.

  extension Deque: StreamInitializable, _StreamUnroutableContainer {
    public static func streamInitialValue() -> Self { [] }
  }

  extension BitArray: StreamInitializable, _StreamUnroutableContainer {
    public static func streamInitialValue() -> Self { [] }
  }

  extension OrderedDictionary: StreamInitializable, _StreamUnroutableContainer {
    public static func streamInitialValue() -> Self { [:] }
  }

  extension TreeDictionary: StreamInitializable, _StreamUnroutableContainer {
    public static func streamInitialValue() -> Self { [:] }
  }

  // MARK: - Bridging

  // StreamDictionary keeps insertion order, so this conversion is lossless in both directions.
  extension OrderedDictionary where Key == String {
    public init(_ streamDictionary: StreamDictionary<Value>) {
      self.init(minimumCapacity: streamDictionary.count)
      for element in streamDictionary { self[element.key] = element.value }
    }
  }

  extension StreamDictionary {
    public init(_ orderedDictionary: OrderedDictionary<String, Value>) {
      self.init()
      for (key, value) in orderedDictionary { self.updateValue(value, forKey: key) }
    }
  }

  // Order is not preserved here, because TreeDictionary does not have one.
  extension TreeDictionary where Key == String {
    public init(_ streamDictionary: StreamDictionary<Value>) {
      self.init()
      for element in streamDictionary { self[element.key] = element.value }
    }
  }

  // MARK: - Legacy handler registration

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
