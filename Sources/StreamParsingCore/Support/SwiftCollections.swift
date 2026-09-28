#if SwiftCollections
  import OrderedCollections
  import HashTreeCollections
  import DequeModule
  import BitCollections

  // MARK: - Conversion protocols

  // Destinations to convert into, not members to parse into: only `[T]` and `[String: T]` route as
  // containers, and none of these is `StreamParseable`, so declaring one as a member of a parseable
  // type is a compile error rather than a value that silently stays empty.

  extension Deque: StreamInitializable {
    public static func streamInitialValue() -> Self { [] }
  }

  extension BitArray: StreamInitializable {
    public static func streamInitialValue() -> Self { [] }
  }

  extension OrderedDictionary: StreamInitializable {
    public static func streamInitialValue() -> Self { [:] }
  }

  extension TreeDictionary: StreamInitializable {
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
#endif
