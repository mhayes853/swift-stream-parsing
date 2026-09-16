import StreamParsingCore
import Testing

// Reproductions for design issues recorded in GENERIC_API_REVIEW.md. These remain expected
// failures until the storage and Unicode contracts are resolved.
@Suite
struct GenericReviewTests {
  @Test
  func appendingToBothArrayCopies() {
    var first = StreamArray([1])
    var second = first
    first.append(2)
    second.append(3)
    withKnownIssue("Two writers reuse the shared tail slot") {
      #expect(Array(first) == [1, 2])
    }
    #expect(Array(second) == [1, 3])
  }

  @Test
  func appendingToBothDictionaryCopies() {
    var first = StreamDictionary(["a": 1])
    var second = first
    first.updateValue(2, forKey: "b")
    second.updateValue(3, forKey: "c")
    withKnownIssue("Dictionary entries and values inherit the shared tail overwrite") {
      #expect(first["b"] == 2)
    }
    #expect(second["c"] == 3)
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
