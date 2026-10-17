import StreamParsing
import Testing

@Suite struct SelectiveObservationTests {
  @Test func projectionFiltersUnrelatedFieldsAndPreservesCompletion() throws {
    let input = [#"{"id":1,"#, #""other":"abc"}"#].map { Array($0.utf8) }
    var iterator = input.partialIterator(of: SequenceModel.self, from: .json())
      .project { $0.id?.value }.removeDuplicateUpdates()
    #expect(try iterator.next() == PartialUpdate(value: 1, isComplete: false))
    #expect(try iterator.next() == PartialUpdate(value: 1, isComplete: true))
    #expect(try iterator.next() == nil)
  }

  @Test func optionalProjectionDoesNotDropNil() throws {
    var iterator = [Array("{}".utf8)].partialIterator(of: SequenceModel.self, from: .json())
      .project { $0.id?.value }.removeDuplicateUpdates()
    let initialUpdate = try iterator.next()
    let initial = try #require(initialUpdate)
    #expect(initial.value == nil)
    #expect(!initial.isComplete)
    let finalUpdate = try iterator.next()
    let final = try #require(finalUpdate)
    #expect(final.value == nil)
    #expect(final.isComplete)
  }

  @Test func snapshotsRemainIndependent() throws {
    var iterator = ["[1,", "2]"].map { Array($0.utf8) }
      .partialIterator(initialValue: StreamArray<Int>(), from: .json())
      .project { $0.value }
    let firstUpdate = try iterator.next()
    let first = try #require(firstUpdate)
    let secondUpdate = try iterator.next()
    let second = try #require(secondUpdate)
    #expect(first.value == [1])
    #expect(second.value == [1, 2])
  }

  @Test func wholeValueFilteringAndCustomComparison() throws {
    var iterator = "12 ".utf8.partialIterator(of: Int.self, from: .json())
      .removeDuplicateUpdates(by: { $0 == $1 })
    var values: [PartialUpdate<Int>] = []
    while let update = try iterator.next() { values.append(update) }
    #expect(
      values == [
        PartialUpdate(value: 0, isComplete: false),
        PartialUpdate(value: 12, isComplete: false),
        PartialUpdate(value: 12, isComplete: true)
      ]
    )
  }

  @Test func projectionErrorsTerminate() throws {
    enum Stop: Error { case now }
    var iterator = [Array("12".utf8)].partialIterator(of: Int.self, from: .json())
      .project { _ throws -> Int in throw Stop.now }
    #expect(throws: Stop.self) { _ = try iterator.next() }
    #expect(try iterator.next() == nil)
  }

  @Test func deduplicationStillValidatesEOF() throws {
    var iterator = ["[", " "].map { Array($0.utf8) }
      .partialIterator(initialValue: StreamArray<Int>(), from: .json())
      .project { _ in 0 }.removeDuplicateUpdates()
    #expect(try iterator.next()?.value == 0)
    #expect(throws: (any Error).self) { _ = try iterator.next() }
    #expect(try iterator.next() == nil)
  }

  @Test func asyncWholeSnapshotFiltering() async throws {
    let source = AsyncStream<[UInt8]> { continuation in
      continuation.yield(Array("12 ".utf8))
      continuation.yield([])
      continuation.finish()
    }
    var iterator = source.partials(of: Int.self, from: .json())
      .removeDuplicateUpdates().makeAsyncIterator()
    #expect(try await iterator.next() == PartialUpdate(value: 12, isComplete: false))
    #expect(try await iterator.next() == PartialUpdate(value: 12, isComplete: true))
    #expect(try await iterator.next() == nil)
  }

  @Test func asyncProjectionCopiesAndCompletion() async throws {
    let source = AsyncStream<[UInt8]> { continuation in
      continuation.yield(Array("12".utf8))
      continuation.yield([])
      continuation.finish()
    }
    let sequence = source.partials(of: Int.self, from: .json()).project { $0.value }
      .removeDuplicateUpdates()
    var iterator = sequence.makeAsyncIterator()
    var copy = iterator
    #expect(try await iterator.next() == PartialUpdate(value: 0, isComplete: false))
    #expect(try await copy.next() == PartialUpdate(value: 12, isComplete: true))
    #expect(try await iterator.next() == nil)
  }

  @Test func asyncCompletionSurvivesIdenticalValue() async throws {
    let source = AsyncStream<[UInt8]> { continuation in
      continuation.yield(Array("12 ".utf8))
      continuation.finish()
    }
    var iterator = source.partials(of: Int.self, from: .json()).project { $0.value }
      .removeDuplicateUpdates().makeAsyncIterator()
    #expect(try await iterator.next() == PartialUpdate(value: 12, isComplete: false))
    #expect(try await iterator.next() == PartialUpdate(value: 12, isComplete: true))
    #expect(try await iterator.next() == nil)
  }

  @Test func asyncUpstreamAndFinalizationErrorsTerminate() async throws {
    enum Stop: Error { case upstream }
    let source = AsyncThrowingStream<[UInt8], any Error> { continuation in
      continuation.yield(Array("12".utf8))
      continuation.finish(throwing: Stop.upstream)
    }
    var iterator = source.partials(of: Int.self, from: .json()).project { $0.value }
      .removeDuplicateUpdates().makeAsyncIterator()
    #expect(try await iterator.next()?.value == 0)
    await #expect(throws: Stop.self) { _ = try await iterator.next() }
    #expect(try await iterator.next() == nil)

    let incomplete = AsyncStream<[UInt8]> { continuation in
      continuation.yield(Array("[".utf8))
      continuation.finish()
    }
    var invalid = incomplete.partials(initialValue: StreamArray<Int>(), from: .json())
      .project { _ in 0 }.removeDuplicateUpdates().makeAsyncIterator()
    #expect(try await invalid.next()?.value == 0)
    await #expect(throws: (any Error).self) { _ = try await invalid.next() }
    #expect(try await invalid.next() == nil)
  }

  @Test func finalProjectionFailureTerminates() throws {
    enum Stop: Error { case final }
    var iterator = [Array("12".utf8)].partialIterator(of: Int.self, from: .json())
      .project { view in
        if view.value == 12 { throw Stop.final }
        return view.value
      }
    #expect(try iterator.next()?.value == 0)
    #expect(throws: Stop.self) { _ = try iterator.next() }
    #expect(try iterator.next() == nil)
  }

  @Test func asyncProjectionErrorsAndSubscribers() async throws {
    enum Stop: Error { case now }
    let source = AsyncStream<[UInt8]> { continuation in
      continuation.yield(Array("12".utf8))
      continuation.finish()
    }
    let sequence = source.partials(of: Int.self, from: .json())
      .project { _ throws -> Int in throw Stop.now }
    var owner = sequence.makeAsyncIterator()
    var copy = owner
    await #expect(throws: Stop.self) { _ = try await owner.next() }
    #expect(try await copy.next() == nil)
    var rejected = sequence.makeAsyncIterator()
    await #expect(throws: StreamParsingError.multipleSubscribers) { _ = try await rejected.next() }
    #expect(try await rejected.next() == nil)
  }
}
