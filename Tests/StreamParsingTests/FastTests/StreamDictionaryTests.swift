import CustomDump
import Testing

import StreamParsingCore

@Suite
struct `Stream dictionary tests` {
  @Test
  func `Preserves insertion order`() {
    var dictionary = StreamDictionary<Int>()
    for key in ["zebra", "apple", "mango"] { dictionary.updateValue(0, forKey: key) }
    #expect(dictionary.keys == ["zebra", "apple", "mango"])
    #expect(dictionary.map(\.key) == ["zebra", "apple", "mango"])
  }

  @Test
  func `Updating an existing key keeps its position`() {
    var dictionary: StreamDictionary<Int> = ["a": 1, "b": 2, "c": 3]
    dictionary.updateValue(99, forKey: "a")
    #expect(dictionary.keys == ["a", "b", "c"])
    #expect(dictionary["a"] == 99)
  }

  // The index is built lazily, so lookups must agree either side of the threshold.
  @Test
  func `Lookups agree before and after the index is built`() {
    var dictionary = StreamDictionary<Int>()
    for i in 0..<40 {
      dictionary.updateValue(i, forKey: "key\(i)")
      for j in 0...i {
        #expect(dictionary["key\(j)"] == j, "after \(i + 1) insertions")
      }
    }
    #expect(dictionary.count == 40)
    #expect(dictionary["missing"] == nil)
  }

  @Test
  func `Updates after the index is built land in the right slot`() {
    var dictionary = StreamDictionary<Int>()
    for i in 0..<20 { dictionary.updateValue(i, forKey: "key\(i)") }
    dictionary.updateValue(999, forKey: "key3")
    dictionary.updateValue(1000, forKey: "key19")
    #expect(dictionary["key3"] == 999)
    #expect(dictionary["key19"] == 1000)
    #expect(dictionary.count == 20)
  }

  @Test
  func `Equality is order sensitive`() {
    let first: StreamDictionary<Int> = ["a": 1, "b": 2]
    let second: StreamDictionary<Int> = ["b": 2, "a": 1]
    let third: StreamDictionary<Int> = ["a": 1, "b": 2]
    #expect(first != second)
    #expect(first == third)
  }

  @Test
  func `Bridges to and from Dictionary`() {
    let stream: StreamDictionary<Int> = ["a": 1, "b": 2, "c": 3]
    let plain = Dictionary(stream)
    #expect(plain == ["a": 1, "b": 2, "c": 3])

    let roundTripped = StreamDictionary(plain)
    #expect(Dictionary(roundTripped) == plain)
  }

  @Test
  func `Is a collection of key value pairs in order`() {
    let dictionary: StreamDictionary<String> = ["one": "1", "two": "2"]
    let pairs = Array(dictionary)
    #expect(pairs.count == 2)
    #expect(pairs[0].key == "one")
    #expect(pairs[0].value == "1")
    #expect(pairs[1].key == "two")
    #expect(pairs[1].value == "2")
    #expect(dictionary.count == 2)
    #expect(!dictionary.isEmpty)
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
      #expect(dictionary[key] == value)
    }
    #expect(dictionary["probe_collision_missing"] == nil)
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

    #expect(dictionary["span_key"] == 9)
    dictionary.updateValue(10, forKey: "next_key")
    #expect(dictionary["span_key"] == 9)
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
    if fnv1a(key) & 127 == 0 {
      keys.append(key)
    }
    candidate += 1
  }
  return keys
}

private func fnv1a(_ key: String) -> UInt64 {
  var hash = UInt64(0xcbf2_9ce4_8422_2325)
  for byte in key.utf8 {
    hash ^= UInt64(byte)
    hash &*= 0x100_0000_01b3
  }
  return hash
}
