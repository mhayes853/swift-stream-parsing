import StreamParsingCore
import Testing

// Copies of the stream collections share storage until one of them is written, so every write has
// to notice the share: copies diverge, the seed a stream starts from is never written into, and
// elements dropped by one copy are released while the other still holds its own.
@Suite("Stream collection copy-on-write tests")
struct StreamCollectionCopyOnWriteTests {
  @Test
  func appendingToBothDictionaryCopies() {
    var first = StreamDictionary(["a": 1])
    var second = first
    first.updateValue(2, forKey: "b")
    second.updateValue(3, forKey: "c")
    #expect(first["b"] == 2)
    #expect(second["c"] == 3)
  }

  @Test(arguments: [0, 1, 7, 8, 9, 31, 32, 255, 256, 257, 511, 512])
  func arrayCopiesDivergeAcrossBlockBoundaries(count: Int) {
    let seed = StreamArray(0..<count)
    var first = seed
    var second = seed
    for value in 0..<20 {
      first.append(1_000 + value)
      second.append(2_000 + value)
    }
    #expect(Array(seed) == Array(0..<count))
    #expect(Array(first) == Array(0..<count) + Array(1_000..<1_020))
    #expect(Array(second) == Array(0..<count) + Array(2_000..<2_020))
  }

  @Test
  func divergentAppendsReleaseReferenceElements() {
    weak var prefix: CollectionElement?
    weak var firstAppend: CollectionElement?
    weak var secondAppend: CollectionElement?
    do {
      var first = StreamArray([CollectionElement(1)])
      var second = first
      prefix = first[0]
      first.append(CollectionElement(2))
      firstAppend = first[1]
      second.append(CollectionElement(3))
      secondAppend = second[1]
      #expect(first[1].value == 2)
      #expect(second[1].value == 3)
      first = StreamArray()
      #expect(firstAppend == nil)
      #expect(prefix != nil)
      #expect(secondAppend != nil)
      withExtendedLifetime(second) {}
    }
    #expect(prefix == nil)
    #expect(firstAppend == nil)
    #expect(secondAppend == nil)
  }

  @Test
  func mutatingASnapshotDoesNotChangeTheContinuingParser() throws {
    var stream = PartialsStream<StreamArray<Int>>(from: .json())
    try stream.next("[1,2,".utf8)
    var snapshot = stream.current
    snapshot.append(9)
    try stream.next("3,4]".utf8)
    #expect(Array(try stream.finish()) == [1, 2, 3, 4])
    #expect(Array(snapshot) == [1, 2, 9])
  }

  @Test
  func copiesCanBeMutatedOnIndependentTasks() async {
    let seed = StreamArray(0..<7)
    let dictionarySeed = StreamDictionary(["seed": seed])
    await withTaskGroup(of: Bool.self) { group in
      for task in 0..<32 {
        group.addTask {
          var array = seed
          var dictionary = dictionarySeed
          for value in 0..<300 { array.append(task * 1_000 + value) }
          dictionary.updateValue(array, forKey: "result")
          var nested = dictionary["seed"]!
          nested.append(task)
          dictionary.updateValue(nested, forKey: "seed")
          return Array(array) == Array(0..<7) + Array(task * 1_000..<task * 1_000 + 300)
            && dictionary["result"] == array
            && Array(dictionary["seed"]!) == Array(0..<7) + [task]
        }
      }
      for await correct in group { #expect(correct) }
    }
    #expect(Array(seed) == Array(0..<7))
    #expect(dictionarySeed.count == 1)
    #expect(Array(dictionarySeed["seed"]!) == Array(0..<7))
  }
}

private final class CollectionElement {
  let value: Int
  init(_ value: Int) { self.value = value }
}
