import StreamParsing
import Testing

@StreamParseable
private struct ObservedModel: Equatable {
  @StreamParseableMember(keyNames: ["title", "heading"])
  var title: String? = nil
  var count: Int? = nil
  var enabled: Bool? = nil
  var items: [Int] = []
  var child: ObservedChild? = nil
}

@StreamParseable
private struct ObservedChild: Equatable {
  var title: String? = nil
}

@StreamParseable(partialMembers: .streamInitialValue)
private struct InitializedObservedModel: Equatable {
  var count: Int = 0
  var child: ObservedChild = ObservedChild()
}

extension ObservedModel.Partial {
  fileprivate var computedTitle: StreamString? { self.title }
}

private struct CustomObservedRoot: StreamParseableRoot {
  var registered: Int?
  var ignored: Int?
  static func streamInitialValue() -> Self { Self() }
  static let streamSchema = StreamSchema(
    shape: .object,
    applyString: { _, _, _ in .applied },
    fields: [
      StreamField(
        key: "registered",
        index: 0,
        kind: .custom,
        optional: true,
        offset: MemoryLayout<Self>.offset(of: \.registered)!
      )
    ]
  )
}

private struct OverlappingObservedRoot: StreamParseableRoot {
  var first = StreamEmptyObject()
  var second = StreamEmptyObject()
  static func streamInitialValue() -> Self { Self() }
  static let streamSchema = StreamSchema(
    shape: .object,
    fields: [
      StreamField(
        key: "first",
        index: 0,
        kind: .container,
        optional: false,
        offset: MemoryLayout<Self>.offset(of: \.first)!
      )
    ]
  )
}

@Suite struct ObservedFieldTests {
  @Test func stringLifecycleAndDocumentCompletion() throws {
    let chunks = ["{", #""title""#, ":", #"""#, "Hi", #"""#, "}"].map { Array($0.utf8) }
    var iterator = try chunks.partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.title).removeDuplicateUpdates()
    var updates: [PartialUpdate<ObservedField<StreamString>>] = []
    while let update = try iterator.next() { updates.append(update) }
    #expect(
      updates == [
        .init(value: .missing, isComplete: false),
        .init(value: .incomplete(""), isComplete: false),
        .init(value: .incomplete("Hi"), isComplete: false),
        .init(value: .complete("Hi"), isComplete: false),
        .init(value: .complete("Hi"), isComplete: true)
      ]
    )
  }

  @Test func missingAndNullAreDifferent() throws {
    for json in ["{}", #"{"title":null}"#] {
      var iterator = try [Array(json.utf8)].partialIterator(of: ObservedModel.self, from: .json())
        .observeField(\.title)
      let expected: ObservedField<StreamString> = json == "{}" ? .missing : .null
      #expect(try iterator.next() == .init(value: expected, isComplete: false))
      #expect(try iterator.next() == .init(value: expected, isComplete: true))
      #expect(try iterator.next() == nil)
    }
  }

  @Test func incompleteLiteralDoesNotLookLikeMissingOrNull() throws {
    let input = [#"{"title":"old","title":"#, "n", "u", "ll", "}"].map { Array($0.utf8) }
    var iterator = try input.partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.title).removeDuplicateUpdates()
    var states: [ObservedField<StreamString>] = []
    while let update = try iterator.next() { states.append(update.value) }
    #expect(states == [.complete("old"), .incomplete(nil), .null, .null])
  }

  @Test func numberAndBooleanWaitForRepresentableValues() throws {
    let chunks = [#"{"count":"#, "1", "2", ",", #""enabled":t"#, "rue", "}"].map { Array($0.utf8) }
    var numbers = try chunks.partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.count).removeDuplicateUpdates()
    var numberStates: [ObservedField<Int>] = []
    while let update = try numbers.next() { numberStates.append(update.value) }
    #expect(numberStates == [.missing, .incomplete(nil), .complete(12), .complete(12)])
    var booleans = try chunks.partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.enabled).removeDuplicateUpdates()
    var booleanStates: [ObservedField<Bool>] = []
    while let update = try booleans.next() { booleanStates.append(update.value) }
    #expect(booleanStates == [.missing, .incomplete(nil), .complete(true), .complete(true)])
  }

  @Test func containerStateAndSnapshots() throws {
    let chunks = [#"{"items":["#, "1,", "2]", "}"].map { Array($0.utf8) }
    var iterator = try chunks.partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.items)
    var states: [ObservedField<StreamArray<Int>>] = []
    while let update = try iterator.next() { states.append(update.value) }
    #expect(
      states == [
        .incomplete([]), .incomplete([1]), .complete([1, 2]),
        .complete([1, 2]), .complete([1, 2])
      ]
    )
  }

  @Test func nestedKeysAndSkippedSubtreesDoNotChangeRootObservation() throws {
    let chunks = [
      #"{"child":{"title":"nested"},"unknown":{"title":"ignored"},"#,
      #""heading":"root","child":{"title":"more"}}"#
    ]
    .map { Array($0.utf8) }
    var iterator = try chunks.partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.title)
    #expect(try iterator.next()?.value == .missing)
    #expect(try iterator.next()?.value == .complete("root"))
    #expect(try iterator.next()?.value == .complete("root"))
  }

  @Test func objectCompletionIsNotModelCompleteness() throws {
    let chunks = [#"{"child":{"#, "}", "}"].map { Array($0.utf8) }
    var iterator = try chunks.partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.child)
    let first = try iterator.next()
    guard case .incomplete(.some(let openChild)) = first?.value else {
      Issue.record("Expected an incomplete child object")
      return
    }
    #expect(openChild.title == nil)
    let second = try iterator.next()
    guard case .complete(let closedChild) = second?.value else {
      Issue.record("Expected a completed child object")
      return
    }
    #expect(closedChild.title == nil)
    #expect(second?.isComplete == false)
  }

  @Test func aliasesEscapesAndAllChunkBoundaries() throws {
    let bytes = Array(#"{"heading":"a\u00e9😀","child":{"title":"nested"},"count":12}"#.utf8)
    for threshold in [0, Int.max] {
      for split in 0...bytes.count {
        let chunks = [Array(bytes[..<split]), Array(bytes[split...])]
        var iterator =
          try chunks.partialIterator(
            of: ObservedModel.self,
            from: .json(windowThreshold: threshold)
          )
          .observeField(\.title)
        var final: PartialUpdate<ObservedField<StreamString>>?
        while let update = try iterator.next() { final = update }
        #expect(final == .init(value: .complete("aé😀"), isComplete: true))
      }
    }
  }

  @Test func byteAndNoncontiguousInput() throws {
    let bytes = Array(#"{"title":"hi"}"#.utf8)
    var iterator = try bytes.partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.title).removeDuplicateUpdates()
    var states: [ObservedField<StreamString>] = []
    while let update = try iterator.next() { states.append(update.value) }
    #expect(
      states == [
        .missing, .incomplete(""), .incomplete("h"), .incomplete("hi"),
        .complete("hi"), .complete("hi")
      ]
    )
    var noncontiguous = try [AnySequence(bytes)]
      .partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.title)
    #expect(try noncontiguous.next()?.value == .complete("hi"))
  }

  @Test func initialValuesDoNotInventPresence() throws {
    let path = try ObservedFieldPath<ObservedModel.Partial, StreamString>(\.title)
    var seeded = try [Array("{}".utf8)]
      .partialIterator(
        initialValue: ObservedModel.Partial(title: "seed"),
        from: .json()
      )
      .observeField(path)
    #expect(try seeded.next()?.value == .missing)
    let numberPath = try ObservedFieldPath<InitializedObservedModel.Partial, Int>(\.count)
    var initialized = try [Array(#"{"count":7}"#.utf8)]
      .partialIterator(of: InitializedObservedModel.self, from: .json()).observeField(numberPath)
    #expect(try initialized.next()?.value == .complete(7))
  }

  @Test func repeatsPreserveTypedAccumulationButTrackNewTokens() throws {
    let chunks = [#"{"title":"a","heading":"#, #""b"}"#].map { Array($0.utf8) }
    var iterator = try chunks.partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.title)
    #expect(try iterator.next()?.value == .complete("a"))
    #expect(try iterator.next()?.value == .complete("ab"))
  }

  @Test func rejectsComputedNestedAndUndeclaredFields() throws {
    #expect(throws: FieldObservationError.unsupportedField) {
      _ = try ObservedFieldPath<ObservedModel.Partial, StreamString>(\.computedTitle)
    }
    #expect(throws: FieldObservationError.unsupportedField) {
      _ = try ObservedFieldPath<InitializedObservedModel.Partial, StreamString>(\.child.title)
    }
    #expect(throws: FieldObservationError.unsupportedField) {
      _ = try ObservedFieldPath<StreamArray<Int>, Int>(\.count)
    }
  }

  @Test func rejectsUnregisteredFieldAndMissingCustomOutput() throws {
    #expect(throws: FieldObservationError.unsupportedField) {
      _ = try ObservedFieldPath<CustomObservedRoot, Int>(\.ignored)
    }
    var iterator = try [Array(#"{"registered":"accepted but ignored"}"#.utf8)]
      .partialIterator(of: CustomObservedRoot.self, from: .json()).observeField(\.registered)
    #expect(throws: FieldObservationError.unavailableValue) { _ = try iterator.next() }
    #expect(try iterator.next() == nil)
  }

  @Test func duplicateNumbersDoNotExposeEarlierValueAsNewPartial() throws {
    let chunks = [#"{"count":42,"count":"#, "1", "2}"].map { Array($0.utf8) }
    var iterator = try chunks.partialIterator(of: ObservedModel.self, from: .json())
      .observeField(\.count)
    #expect(try iterator.next()?.value == .complete(42))
    #expect(try iterator.next()?.value == .incomplete(nil))
    #expect(try iterator.next()?.value == .complete(12))
  }

  @Test func escapedKeyAliasesAreRecognized() throws {
    var iterator = try [Array(#"{"he\u0061ding":"title"}"#.utf8)]
      .partialIterator(of: ObservedModel.self, from: .json()).observeField(\.title)
    #expect(try iterator.next()?.value == .complete("title"))
  }

  @Test func asyncParserAndEOFErrorsTerminate() async throws {
    for json in [#"{"title":1}"#, #"{"title":"open"#] {
      let input = AsyncStream<[UInt8]> { continuation in
        continuation.yield(Array(json.utf8))
        continuation.finish()
      }
      var iterator = try input.partials(of: ObservedModel.self, from: .json())
        .observeField(\.title).removeDuplicateUpdates().makeAsyncIterator()
      var threw = false
      do { while try await iterator.next() != nil {} } catch { threw = true }
      #expect(threw)
      #expect(try await iterator.next() == nil)
    }
  }

  @Test func overlappingZeroSizedFieldsAreRejected() throws {
    #expect(
      MemoryLayout<OverlappingObservedRoot>.offset(of: \.first)
        == MemoryLayout<OverlappingObservedRoot>.offset(of: \.second)
    )
    #expect(throws: FieldObservationError.unsupportedField) {
      _ = try ObservedFieldPath<OverlappingObservedRoot, StreamEmptyObject>(\.first)
    }
    #expect(throws: FieldObservationError.unsupportedField) {
      _ = try ObservedFieldPath<OverlappingObservedRoot, StreamEmptyObject>(\.second)
    }
  }

  @Test func rejectsLateInstallation() throws {
    var iterator = "{}".utf8.partialIterator(of: ObservedModel.self, from: .json())
    _ = try iterator.next()
    do {
      _ = try iterator.observeField(\.title)
      Issue.record("Late observation should fail")
    } catch {
      #expect(error as? FieldObservationError == .alreadyStarted)
    }
  }

  @Test func parserAndFinishErrorsTerminate() throws {
    for chunks in [[#"{"title":1}"#], [#"{"title":"x"#], [#"{"title":"ok"}"#, "?"]] {
      var iterator = try chunks.map { Array($0.utf8) }
        .partialIterator(of: ObservedModel.self, from: .json()).observeField(\.title)
      var threw = false
      do { while try iterator.next() != nil {} } catch { threw = true }
      #expect(threw)
      #expect(try iterator.next() == nil)
    }
  }

  @Test func asyncCopiesShareTrackingAndRejectOtherSubscribers() async throws {
    let input = AsyncStream<[UInt8]> { continuation in
      for chunk in [#"{"title":"#, #""hi"#, #""}"#] { continuation.yield(Array(chunk.utf8)) }
      continuation.finish()
    }
    let source = input.partials(of: ObservedModel.self, from: .json())
    let sequence = try source.observeField(\.title)
    var owner = sequence.makeAsyncIterator()
    var copy = owner
    #expect(try await owner.next()?.value == .missing)
    #expect(try await copy.next()?.value == .incomplete("hi"))
    var rejected = source.makeAsyncIterator()
    await #expect(throws: StreamParsingError.multipleSubscribers) { _ = try await rejected.next() }
    #expect(try await owner.next()?.value == .complete("hi"))
    #expect(try await copy.next() == .init(value: .complete("hi"), isComplete: true))
    #expect(try await owner.next() == nil)
  }

  @Test func asyncFilteringPreservesFieldAndDocumentCompletion() async throws {
    let input = AsyncStream<[UInt8]> { continuation in
      for chunk in [#"{"title":"hi"#, #"""#, "}"] { continuation.yield(Array(chunk.utf8)) }
      continuation.finish()
    }
    var iterator = try input.partials(of: ObservedModel.self, from: .json())
      .observeField(\.title).removeDuplicateUpdates().makeAsyncIterator()
    #expect(try await iterator.next() == .init(value: .incomplete("hi"), isComplete: false))
    #expect(try await iterator.next() == .init(value: .complete("hi"), isComplete: false))
    #expect(try await iterator.next() == .init(value: .complete("hi"), isComplete: true))
    #expect(try await iterator.next() == nil)
  }

  @Test func asyncFailuresTerminateCopies() async throws {
    enum Stop: Error { case upstream }
    let input = AsyncThrowingStream<[UInt8], any Error> { continuation in
      continuation.yield(Array(#"{"title":"x"#.utf8))
      continuation.finish(throwing: Stop.upstream)
    }
    var iterator = try input.partials(of: ObservedModel.self, from: .json())
      .observeField(\.title).makeAsyncIterator()
    var copy = iterator
    #expect(try await iterator.next()?.value == .incomplete("x"))
    await #expect(throws: Stop.self) { _ = try await copy.next() }
    #expect(try await iterator.next() == nil)
  }
}
