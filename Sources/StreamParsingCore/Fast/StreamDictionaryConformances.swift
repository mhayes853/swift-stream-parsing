// Order sensitive, like `==`: entries combine in insertion order.
extension StreamDictionary: Hashable where Value: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.count)
    for (key, value) in self {
      hasher.combine(key)
      hasher.combine(value)
    }
  }
}

#if !hasFeature(Embedded)
  // Otherwise a reflecting printer dumps the entries, the slot table and the pending value.
  extension StreamDictionary: CustomReflectable {
    public var customMirror: Mirror {
      Mirror(self, unlabeledChildren: Array(self), displayStyle: .dictionary)
    }
  }

  // A keyed container with `String` keys, encoding as the object it stands in for, in insertion
  // order. Outside the Embedded subset.
  extension StreamDictionary: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: StreamDictionaryCodingKey.self)
      for (key, value) in self {
        try container.encode(value, forKey: StreamDictionaryCodingKey(stringValue: key))
      }
    }
  }

  // Keys insert sorted, as `init(_: [String: Value])` does: `allKeys` promises no order, and
  // `JSONDecoder`'s is not the document's.
  extension StreamDictionary: Decodable where Value: Decodable {
    public init(from decoder: any Decoder) throws {
      self.init()
      let container = try decoder.container(keyedBy: StreamDictionaryCodingKey.self)
      let keys = container.allKeys.sorted { $0.stringValue < $1.stringValue }
      self.reserveCapacity(keys.count)
      for key in keys {
        self.updateValue(try container.decode(Value.self, forKey: key), forKey: key.stringValue)
      }
    }
  }

  private struct StreamDictionaryCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
      self.stringValue = stringValue
    }

    init?(intValue: Int) {
      self.stringValue = String(intValue)
    }
  }
#endif
