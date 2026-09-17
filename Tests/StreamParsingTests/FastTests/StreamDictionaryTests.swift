import CustomDump
import Foundation
import Testing

@testable import StreamParsingCore

@Suite
struct `Stream dictionary tests` {
  @Test
  func `Initial Capacity Reserves Flat Storage And The Final Table`() {
    var dictionary = StreamDictionary<Int>(initialCapacity: 100)

    expectNoDifference(dictionary.entries.capacity >= 100, true)
    expectNoDifference(
      dictionary.storedValues.blocks.capacity
        >= 100 / StreamArray<Int>.defaultBlockCapacity,
      true
    )
    expectNoDifference(
      dictionary.storedValues.tail?.slotCapacity,
      Swift.min(100, StreamArray<Int>.defaultBlockCapacity)
    )
    expectNoDifference(dictionary.table.count, 256)
    for value in 0..<100 { dictionary.updateValue(value, forKey: "key\(value)") }
    expectNoDifference(dictionary.count, 100)
    for value in 0..<100 { expectNoDifference(dictionary["key\(value)"], value) }
  }

  @Test
  func `Small Initial Capacity Keeps Linear Lookup`() {
    var dictionary = StreamDictionary<Int>(initialCapacity: 8)
    expectNoDifference(dictionary.table.isEmpty, true)
    for value in 0..<12 { dictionary.updateValue(value, forKey: "key\(value)") }
    expectNoDifference(dictionary.table.count, 32)
  }

  @Test
  func `Preserves insertion order`() {
    var dictionary = StreamDictionary<Int>()
    for key in ["zebra", "apple", "mango"] { dictionary.updateValue(0, forKey: key) }
    expectNoDifference(dictionary.keys, ["zebra", "apple", "mango"])
    expectNoDifference(dictionary.map(\.key), ["zebra", "apple", "mango"])
  }

  @Test
  func `Updating an existing key keeps its position`() {
    var dictionary: StreamDictionary<Int> = ["a": 1, "b": 2, "c": 3]
    dictionary.updateValue(99, forKey: "a")
    expectNoDifference(dictionary.keys, ["a", "b", "c"])
    expectNoDifference(dictionary["a"], 99)
  }

  // The index is built lazily, so lookups must agree either side of the threshold.
  @Test
  func `Lookups agree before and after the index is built`() {
    var dictionary = StreamDictionary<Int>()
    for i in 0..<40 {
      dictionary.updateValue(i, forKey: "key\(i)")
      for j in 0...i {
        expectNoDifference(dictionary["key\(j)"], j, "after \(i + 1) insertions")
      }
    }
    expectNoDifference(dictionary.count, 40)
    expectNoDifference(dictionary["missing"], nil)
  }

  @Test
  func `Updates after the index is built land in the right slot`() {
    var dictionary = StreamDictionary<Int>()
    for i in 0..<20 { dictionary.updateValue(i, forKey: "key\(i)") }
    dictionary.updateValue(999, forKey: "key3")
    dictionary.updateValue(1000, forKey: "key19")
    expectNoDifference(dictionary["key3"], 999)
    expectNoDifference(dictionary["key19"], 1000)
    expectNoDifference(dictionary.count, 20)
  }

  @Test
  func `Equality is order sensitive`() {
    let first: StreamDictionary<Int> = ["a": 1, "b": 2]
    let second: StreamDictionary<Int> = ["b": 2, "a": 1]
    let third: StreamDictionary<Int> = ["a": 1, "b": 2]
    expectNoDifference(first != second, true)
    expectNoDifference(first, third)
  }

  @Test
  func `Bridges to and from Dictionary`() {
    let stream: StreamDictionary<Int> = ["a": 1, "b": 2, "c": 3]
    let plain = Dictionary(stream)
    expectNoDifference(plain, ["a": 1, "b": 2, "c": 3])

    let roundTripped = StreamDictionary(plain)
    expectNoDifference(Dictionary(roundTripped), plain)
  }

  @Test
  func `Is a collection of key value pairs in order`() {
    let dictionary: StreamDictionary<String> = ["one": "1", "two": "2"]
    let pairs = Array(dictionary)
    expectNoDifference(pairs.count, 2)
    expectNoDifference(pairs[0].key, "one")
    expectNoDifference(pairs[0].value, "1")
    expectNoDifference(pairs[1].key, "two")
    expectNoDifference(pairs[1].value, "2")
    expectNoDifference(dictionary.count, 2)
    expectNoDifference(!dictionary.isEmpty, true)
  }

  @Test
  func `Handles Many Keys Sharing The Initial Probe Slot`() {
    let keys = adversarialKeys(count: 40)
    var dictionary = StreamDictionary<Int>()
    for (value, key) in keys.enumerated() {
      dictionary.updateValue(value, forKey: key)
    }

    expectNoDifference(dictionary.map(\.key), keys)
    expectNoDifference(dictionary.map(\.value), keys.indices.map { $0 })
    for (value, key) in keys.enumerated() {
      expectNoDifference(dictionary[key], value)
    }
    expectNoDifference(dictionary["probe_collision_missing"], nil)
  }

  @Test
  func `Resumes A Value Through A Borrowed Key Span`() {
    var dictionary = StreamDictionary<Int>()
    let key = Array("span_key".utf8)

    key.withUnsafeBufferPointer { buffer in
      let pointer = dictionary._openValue(
        forKey: Span(_unsafeElements: buffer),
        initial: 1
      )
      pointer.assumingMemoryBound(to: Int.self).pointee = 1
    }
    key.withUnsafeBufferPointer { buffer in
      let pointer = dictionary._openValue(
        forKey: Span(_unsafeElements: buffer),
        initial: 2
      )
      pointer.assumingMemoryBound(to: Int.self).pointee = 9
    }

    expectNoDifference(dictionary["span_key"], 9)
    dictionary.updateValue(10, forKey: "next_key")
    expectNoDifference(dictionary["span_key"], 9)
  }

  @Test
  func `Indexes A New Key Before Its Value Is Drained`() {
    var dictionary = StreamDictionary<Int>()
    for value in 0..<8 {
      dictionary.updateValue(value, forKey: "key_\(value)")
    }
    let key = Array("key_8".utf8)

    key.withUnsafeBufferPointer { buffer in
      let pointer = dictionary._openValue(
        forKey: Span(_unsafeElements: buffer),
        initial: 8
      )
      pointer.assumingMemoryBound(to: Int.self).pointee = 80
    }

    expectNoDifference(dictionary.entries.count, 9)
    expectNoDifference(dictionary.storedValues.count, 8)
    expectNoDifference(dictionary.table.count, 32)
    expectNoDifference(dictionary["key_8"], 80)

    dictionary.updateValue(9, forKey: "key_9")
    expectNoDifference(dictionary.storedValues.count, 10)
    expectNoDifference(dictionary["key_8"], 80)
    expectNoDifference(dictionary["key_9"], 9)
  }

  @Test
  func `An Indexed Miss Claims Its Located Vacant Bucket`() {
    let keys = adversarialKeys(count: 11)
    var dictionary = StreamDictionary<Int>()
    for (value, key) in keys.prefix(10).enumerated() {
      dictionary.updateValue(value, forKey: key)
    }
    let key = Array(keys[10].utf8)
    var vacantBucket = -1
    let existing = key.withUnsafeBufferPointer { buffer in
      dictionary.slot(
        forKey: buffer,
        hash: StreamDictionary<Int>.hash(buffer),
        vacantBucket: &vacantBucket
      )
    }

    expectNoDifference(existing, nil)
    expectNoDifference(vacantBucket, 10)

    key.withUnsafeBufferPointer { buffer in
      dictionary._openValue(
        forKey: Span(_unsafeElements: buffer),
        initial: 10
      ).assumingMemoryBound(to: Int.self).pointee = 100
    }

    expectNoDifference(dictionary.table[10], 10)
    expectNoDifference(dictionary[keys[10]], 100)
  }
}

extension `Stream dictionary tests` {
  // The same shrink, reached through the value storage `reserveCapacity` forwards to.
  @Test
  func `A Smaller Late Reservation Does Not Shrink The Value Storage Schedule`() {
    var dictionary = StreamDictionary<Int>(initialCapacity: 100_000)
    let hinted = dictionary.storedValues.currentBlockCapacity
    dictionary.reserveCapacity(10)

    expectNoDifference(dictionary.storedValues.currentBlockCapacity, hinted)
    for value in 0..<600 { dictionary.updateValue(value, forKey: "key\(value)") }
    expectNoDifference(dictionary.count, 600)
    expectNoDifference(dictionary["key599"], 599)
    expectNoDifference(dictionary["key512"], 512)
  }
}

// MARK: - Conformances

extension `Stream dictionary tests` {
  // A dictionary whose last entry is still open, as the parser leaves one mid-value.
  private func withOpenEntry() -> StreamDictionary<Int> {
    var dictionary: StreamDictionary<Int> = ["b": 2]
    Array("a".utf8).withUnsafeBufferPointer { buffer in
      dictionary._openValue(forKey: Span(_unsafeElements: buffer), initial: 0)
        .assumingMemoryBound(to: Int.self).pointee = 1
    }
    return dictionary
  }

  @Test
  func `Reflects as its key-value pairs in insertion order`() {
    let mirror = Mirror(reflecting: self.withOpenEntry())
    expectNoDifference(mirror.displayStyle, .dictionary)
    let pairs = mirror.children.map { $0.value as! (key: String, value: Int) }
    expectNoDifference(pairs.map(\.key), ["b", "a"])
    expectNoDifference(pairs.map(\.value), [2, 1])

    var dumped = ""
    dump(self.withOpenEntry(), to: &dumped)
    #expect(dumped.contains(#"key: "a""#))
    #expect(!dumped.contains("storedValues") && !dumped.contains("pendingValue"))
  }

  @Test
  func `Encodes as a JSON object with string keys`() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    expectNoDifference(
      String(decoding: try encoder.encode(self.withOpenEntry()), as: UTF8.self),
      #"{"a":1,"b":2}"#
    )
    let nested: StreamDictionary<StreamArray<StreamString>> = ["k": ["x", "y"], "1": []]
    expectNoDifference(
      try encoder.encode(nested),
      try encoder.encode(["k": ["x", "y"], "1": [String]()])
    )
  }

  @Test
  func `Decodes a JSON object with its keys in sorted order`() throws {
    let decoded = try JSONDecoder().decode(
      StreamDictionary<Int>.self, from: Data(#"{"zebra":1,"apple":2,"mango":3}"#.utf8)
    )
    expectNoDifference(decoded.keys, ["apple", "mango", "zebra"])
    expectNoDifference(decoded.values, [2, 3, 1])

    let nested = try JSONDecoder().decode(
      StreamDictionary<StreamDictionary<StreamString>?>.self,
      from: Data(#"{"a":{"x":"y"},"b":null}"#.utf8)
    )
    expectNoDifference(nested["a"]??["x"], "y")
    expectNoDifference(nested["b"], .some(nil))

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(StreamDictionary<Int>.self, from: Data("[1]".utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(StreamDictionary<Int>.self, from: Data(#"{"a":"x"}"#.utf8))
    }
  }

  @Test
  func `Codable round trips a sorted dictionary`() throws {
    let value: StreamDictionary<Int> = ["a": 1, "b": 2, "c": 3]
    let decoded = try JSONDecoder().decode(
      StreamDictionary<Int>.self, from: try JSONEncoder().encode(value)
    )
    expectNoDifference(decoded, value)
  }

  @Test
  func `Hashes consistently with equality`() {
    // Equal however they were built: literal, repeated key, open entry.
    var updated: StreamDictionary<Int> = ["b": 0, "a": 1]
    updated.updateValue(2, forKey: "b")
    let values = [self.withOpenEntry(), ["b": 2, "a": 1], updated]
    for value in values {
      expectNoDifference(value, values[0])
      expectNoDifference(value.hashValue, values[0].hashValue)
    }

    // Order sensitive, like `==`.
    let reordered: StreamDictionary<Int> = ["a": 1, "b": 2]
    #expect(reordered != values[0])
    expectNoDifference(Set(values + [reordered]).count, 2)
  }
}

// All generated keys land in slot zero for every table size used while these entries are
// inserted. This exercises linear probing across the threshold and each table rebuild without
// relying on a probabilistic collision.
private func adversarialKeys(count: Int) -> [String] {
  var keys = [String]()
  var candidate = 0
  while keys.count < count {
    let key = "probe_collision_\(candidate)"
    if StreamDictionary<Int>.hash(key) & 127 == 0 {
      keys.append(key)
    }
    candidate += 1
  }
  return keys
}
