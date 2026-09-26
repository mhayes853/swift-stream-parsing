import StreamParsingCore
import Testing

// Regressions and remaining Unicode reproductions from GENERIC_API_REVIEW.md.
@Suite
struct GenericReviewTests {
  @Test
  func appendingToBothArrayCopies() {
    var first = StreamArray([1])
    var second = first
    first.append(2)
    second.append(3)
    #expect(Array(first) == [1, 2])
    #expect(Array(second) == [1, 3])
  }

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
  func streamsSeededFromTheSameNestedCollectionsDiverge() throws {
    let seed = StreamDictionary(["values": StreamArray([1])])
    var first = PartialsStream(initialValue: seed, from: .json())
    var second = PartialsStream(initialValue: seed, from: .json())
    try first.next("{\"values\":[2,3]}".utf8)
    try second.next("{\"values\":[4,5]}".utf8)
    #expect(Array(try first.finish()["values"]!) == [1, 2, 3])
    #expect(Array(try second.finish()["values"]!) == [1, 4, 5])
    #expect(Array(seed["values"]!) == [1])
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

  @Test
  func dictionaryKeyLookupDoesNotDependOnPendingState() throws {
    var stream = PartialsStream<StreamDictionary<Int>>(from: .json())
    try stream.next("{\"é\":1,".utf8)
    let pending = stream.current["e\u{301}"]
    try stream.next("\"other\":2}".utf8)
    let closed = try stream.finish()["e\u{301}"]
    withKnownIssue("Pending keys use String equality; stored keys use byte equality") {
      #expect(pending == closed)
    }
  }

  @Test
  func repairedCharacterTraversalDoesNotRepeatCombiningMarks() {
    let bytes = Array("a\u{301}".utf8) + [0xFF]
    var value = StreamString()
    bytes.withUnsafeBufferPointer { buffer in
      value.streamAppend(utf8: Span(_unsafeElements: buffer))
    }
    withKnownIssue("Malformed lookahead advances one scalar after emitting a whole grapheme") {
      #expect(Array(value.characters) == Array(String(value)))
    }
  }
}

private final class CollectionElement {
  let value: Int
  init(_ value: Int) { self.value = value }
}
