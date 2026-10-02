import StreamParsing
import Testing

@Suite struct PartialIteratorTests {
  @Test func chunksAndCompletion() throws {
    let chunks = ["[1,", "", "2]"].map { Array($0.utf8) }
    var iterator = chunks.partialIterator(initialValue: StreamArray<Int>(), from: .json())
    var updates: [PartialUpdate<StreamArray<Int>>] = []
    while let update = try iterator.next() { updates.append(update) }
    #expect(updates.map(\.value) == [[1], [1], [1, 2], [1, 2]])
    #expect(updates.map(\.isComplete) == [false, false, false, true])
    #expect(try iterator.next() == nil)
  }

  @Test func byteAndTypeOverloads() throws {
    var iterator = #"{"id":1}"#.utf8.partialIterator(of: SequenceModel.self, from: .json())
    var last: SequenceModel.Partial?
    while let update = try iterator.next() { last = update.value }
    #expect(last?.id == 1)
    var root = [Array("12".utf8)].partialIterator(of: Int.self, from: .json())
    #expect(try root.next()?.isComplete == false)
    #expect(try root.next()?.value == 12)
  }

  @Test func errorsTerminate() throws {
    for input in ["?", "[1", ""] {
      var iterator = [Array(input.utf8)]
        .partialIterator(initialValue: StreamArray<Int>(), from: .json())
      var threw = false
      do { while try iterator.next() != nil {} } catch { threw = true }
      #expect(threw)
      #expect(try iterator.next() == nil)
    }
  }

  @Test func scopedViewsAndFinalNumber() throws {
    var values: [Int] = []
    var completion: [Bool] = []
    try [Array("12".utf8)]
      .withPartialViews(of: Int.self, from: .json()) { view, final in
        values.append(view.value)
        completion.append(final)
      }
    #expect(values == [0, 12])
    #expect(completion == [false, true])
    var id: Int?
    try #"{"id":3}"#.utf8
      .withPartialViews(of: SequenceModel.self, from: .json()) { view, _ in
        id = view.id?.value
      }
    #expect(id == 3)
  }

  @Test func lazyConsumptionAndErrorDoesNotReadAhead() throws {
    var reads = 0
    let input = AnySequence {
      AnyIterator<UInt8> {
        reads += 1
        return UInt8(ascii: "?")
      }
    }
    var iterator = input.partialIterator(of: Int.self, from: .json())
    #expect(reads == 0)
    #expect(throws: (any Error).self) { _ = try iterator.next() }
    #expect(try iterator.next() == nil)
    #expect(reads == 1)
  }

  @Test func finalCallbackFailureLeavesStreamFinished() throws {
    enum Stop: Error { case now }
    var stream = PartialsStream(initialValue: 0, from: .json())
    try stream.next("12".utf8)
    #expect(throws: Stop.self) {
      try stream.finishWithView { _ in throw Stop.now }
    }
    #expect(throws: StreamParsingError.parserFinished) { try stream.next(UInt8(ascii: " ")) }
  }

  @Test func callbackFailureStopsInput() throws {
    enum Stop: Error { case now }
    var reads = 0
    let input = AnySequence {
      AnyIterator<UInt8> {
        reads += 1
        return UInt8(ascii: " ")
      }
    }
    #expect(throws: Stop.self) {
      try input.withPartialViews(initialValue: 0, from: .json()) { _, _ in throw Stop.now }
    }
    #expect(reads == 1)
  }
}
