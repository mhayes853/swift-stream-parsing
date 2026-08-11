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
}
