import StreamParsing
import Testing

@testable import StreamParsingCore

private enum ConversionTestError: Error { case invalid }
private enum TextConversion: StreamCompletedValueConversion {
  typealias Source = StreamString
  static let calls = _StreamLock((to: 0, from: 0))
  static func convertToValue(_ source: borrowing Source.View) throws(ConversionTestError) -> String
  {
    calls.withLock { $0.to += 1 }
    let text = String(source.value)
    guard text != "bad" else { throw ConversionTestError.invalid }
    return text.uppercased()
  }
  static func convertFromValue(_ value: String) -> Source {
    calls.withLock { $0.from += 1 }
    return StreamString(value.lowercased())
  }
}
private enum NumberConversion: StreamCompletedValueConversion {
  typealias Source = Int
  static func convertToValue(_ source: borrowing Source.View) throws(ConversionTestError) -> Int {
    guard source.value >= 0 else { throw ConversionTestError.invalid }
    return source.value * 2
  }
  static func convertFromValue(_ value: Int) -> Int { value / 2 }
}
private enum BooleanConversion: StreamCompletedValueConversion {
  typealias Source = Bool
  static func convertToValue(_ source: borrowing Source.View) -> String {
    source.value ? "yes" : "no"
  }
  static func convertFromValue(_ value: String) -> Bool { value == "yes" }
}
private enum PairConversion: StreamCompletedValueConversion {
  typealias Source = StreamArray<Int>
  static let calls = _StreamLock(0)
  static func convertToValue(_ source: borrowing Source.View) throws(ConversionTestError) -> Int {
    calls.withLock { $0 += 1 }
    guard source.count == 2 else { throw ConversionTestError.invalid }
    return source.value.reduce(0, +)
  }
  static func convertFromValue(_ value: Int) -> Source { [value, 0] }
}
@StreamParseable
private struct ConversionModel {
  @StreamParseableMember(keyNames: ["text", "alias"], completedConversion: TextConversion.self)
  var text: String = "DEFAULT"
  @StreamParseableMember(completedConversion: NumberConversion.self)
  var count: Int = 10
  @StreamParseableMember(completedConversion: BooleanConversion.self)
  var flag: String? = nil
  @StreamParseableMember(completedConversion: PairConversion.self)
  var pair: Int = 5
  var other: Int = 0
}
@StreamParseable(partialMembers: .streamInitialValue)
private struct InitializedConversionModel {
  @StreamParseableMember(completedConversion: TextConversion.self)
  var text: String = "DEFAULT"
}
@StreamParseable
private struct InnerConversionModel {
  @StreamParseableMember(completedConversion: TextConversion.self)
  var text: String = "DEFAULT"
}
private enum ObjectConversion: StreamCompletedValueConversion {
  typealias Source = InnerConversionModel.Partial
  static func convertToValue(_ source: borrowing Source.View) throws(ConversionTestError) -> String
  {
    guard let text = source.text?.value else { throw ConversionTestError.invalid }
    return text + "!"
  }
  static func convertFromValue(_ value: String) -> Source {
    InnerConversionModel(text: String(value.dropLast())).streamPartialValue
  }
}
@StreamParseable
private struct ObjectConversionModel {
  @StreamParseableMember(completedConversion: ObjectConversion.self)
  var object: String = "DEFAULT!"
}

@Suite(.serialized) struct CompletedValueConversionTests {
  @Test func conversionErrorsKeepTheirConcreteTypes() throws {
    var stream = PartialsStream<ConvertedPartial<NumberConversion>>(from: .json())
    #expect(throws: JSONParsingError.self) { try stream.next("-1 ".utf8) }
    let error: ConversionTestError? = stream.current.conversionError
    #expect(error == .invalid)
    stream.withView { view in
      let error: ConversionTestError? = view.conversionError
      #expect(error == .invalid)
    }
    let nonthrowing: Never? = ConvertedPartial<BooleanConversion>(value: "yes").conversionError
    #expect(nonthrowing == nil)
  }

  @Test func stringsConvertOnlyAtClosingQuoteAndCache() throws {
    TextConversion.calls.withLock { $0 = (0, 0) }
    var stream = PartialsStream<ConversionModel.Partial>(from: .json())
    try stream.next(#"{"text":"he"#.utf8)
    let snapshot = stream.current
    #expect(snapshot.text?.source == "he")
    #expect(snapshot.text?.value == nil)
    #expect(TextConversion.calls.withLock { $0.to } == 0)
    try stream.next(#"llo","other":7}"#.utf8)
    #expect(stream.current.text?.value == "HELLO")
    #expect(snapshot.text?.source == "he")
    let final = try stream.finish()
    #expect(final.text?.value == "HELLO")
    #expect(TextConversion.calls.withLock { $0.to } == 1)
    #expect(ConversionModel(streamPartial: final) == nil)
    #expect(ConversionModel(orInitial: final).count == 10)
  }

  @Test func wholeEscapedEmptyAndEverySplit() throws {
    for json in [#"{"text":"hello"}"#, #"{"alias":"h\u00e9llo"}"#, #"{"text":""}"#] {
      let bytes = Array(json.utf8)
      for threshold in [0, Int.max] {
        for split in 0...bytes.count {
          TextConversion.calls.withLock { $0 = (0, 0) }
          var stream = PartialsStream<ConversionModel.Partial>(
            from: .json(windowThreshold: threshold)
          )
          try stream.next(bytes[..<split])
          try stream.next(bytes[split...])
          let final = try stream.finish()
          #expect(final.text?.value == String(final.text!.source).uppercased())
          #expect(TextConversion.calls.withLock { $0.to } == 1)
        }
      }
    }
  }

  @Test func numberBooleanAndArrayBoundaries() throws {
    PairConversion.calls.withLock { $0 = 0 }
    var stream = PartialsStream<ConversionModel.Partial>(from: .json())
    try stream.next(#"{"count":1"#.utf8)
    #expect(stream.current.count == nil)
    try stream.next(#"2,"flag":tr"#.utf8)
    #expect(stream.current.count?.value == 24)
    #expect(stream.current.flag == nil)
    try stream.next(#"ue,"pair":[1,"#.utf8)
    #expect(stream.current.flag?.value == "yes")
    let snapshot = stream.current
    #expect(snapshot.pair?.source == [1])
    #expect(snapshot.pair?.value == nil)
    try stream.next("2]}".utf8)
    let final = try stream.finish()
    #expect(final.pair?.value == 3)
    #expect(snapshot.pair?.source == [1])
    #expect(PairConversion.calls.withLock { $0 } == 1)
  }

  @Test func reverseConversionAndDefaults() throws {
    TextConversion.calls.withLock { $0 = (0, 0) }
    let value = ConversionModel(text: "HELLO", count: 24, flag: "yes", pair: 3, other: 7)
    let partial = value.streamPartialValue
    #expect(partial.text?.source == "hello")
    #expect(partial.text?.value == "HELLO")
    #expect(TextConversion.calls.withLock { $0.from } == 1)
    #expect(TextConversion.calls.withLock { $0.to } == 0)
    let rebuilt = try #require(ConversionModel(streamPartial: partial))
    #expect(rebuilt.text == value.text)
    #expect(rebuilt.count == value.count)
    #expect(rebuilt.flag == value.flag)
    #expect(rebuilt.pair == value.pair)
    #expect(ConversionModel(orInitial: .init()).text == "DEFAULT")
    #expect(InitializedConversionModel(orInitial: .init()).text == "DEFAULT")
    var initialized = PartialsStream<InitializedConversionModel.Partial>(from: .json())
    try initialized.next(#"{"text":"ok"}"#.utf8)
    #expect(try initialized.finish().text.value == "OK")
  }

  @Test func duplicateOccurrencesResetAndConvertIndividually() throws {
    TextConversion.calls.withLock { $0 = (0, 0) }
    PairConversion.calls.withLock { $0 = 0 }
    var stream = PartialsStream<ConversionModel.Partial>(from: .json())
    try stream.next(#"{"text":"one","pair":[1,2],"text":"t"#.utf8)
    #expect(stream.current.text?.source == "t")
    #expect(stream.current.text?.value == nil)
    try stream.next(#"wo","pair":[3,4]}"#.utf8)
    let final = try stream.finish()
    #expect(final.text?.value == "TWO")
    #expect(final.pair?.source == [3, 4])
    #expect(final.pair?.value == 7)
    #expect(TextConversion.calls.withLock { $0.to } == 2)
    #expect(PairConversion.calls.withLock { $0 } == 2)
  }

  @Test func nestedConversionsCompleteInsideOut() throws {
    var stream = PartialsStream<ObjectConversionModel.Partial>(from: .json())
    try stream.next(#"{"object":{"text":"hi""#.utf8)
    #expect(stream.current.object?.value == nil)
    #expect(stream.current.object?.source.text?.value == "HI")
    try stream.next("}}".utf8)
    #expect(try stream.finish().object?.value == "HI!")
  }

  @Test func optionalMissingNullAndUnfinishedAreDistinctForStrictConversion() throws {
    let complete = ConversionModel().streamPartialValue
    #expect(ConversionModel(streamPartial: complete)?.flag == nil)
    var partial = complete
    partial.flag = ConvertedPartial<BooleanConversion>()
    #expect(ConversionModel(streamPartial: partial) == nil)
    var stream = PartialsStream<ConversionModel.Partial>(from: .json())
    try stream.next(#"{"flag":true,"flag":null}"#.utf8)
    #expect(try stream.finish().flag == nil)
  }

  @Test func invalidCompletedValuesReportConversionFailure() throws {
    for json in [#"{"text":"bad"}"#, #"{"count":-1}"#, #"{"pair":[1]}"#, #"{"object":{}}"#] {
      if json.contains("object") {
        var stream = PartialsStream<ObjectConversionModel.Partial>(from: .json())
        do {
          try stream.next(json.utf8)
          Issue.record("Expected conversion failure")
        } catch let error as JSONParsingError {
          #expect(error.reason == .sinkRejectedToken(.init(reason: .conversionFailed)))
          #expect(stream.current.object?.conversionError == .invalid)
        }
      } else {
        for threshold in [0, Int.max] {
          var stream = PartialsStream<ConversionModel.Partial>(
            from: .json(windowThreshold: threshold)
          )
          do {
            try stream.next(json.utf8)
            Issue.record("Expected conversion failure")
          } catch let error as JSONParsingError {
            #expect(error.reason == .sinkRejectedToken(.init(reason: .conversionFailed)))
          }
        }
      }
    }
  }

  @Test func rootAndCollectionPositions() throws {
    var number = PartialsStream(initialValue: ConvertedPartial<NumberConversion>(), from: .json())
    try number.next("12".utf8)
    #expect(number.current.value == nil)
    #expect(try number.finish().value == 24)
    var strings = PartialsStream(
      initialValue: StreamArray<ConvertedPartial<TextConversion>?>(),
      from: .json()
    )
    try strings.next(#"["a",null,"b"]"#.utf8)
    let result = try strings.finish()
    #expect(result[0]?.value == "A")
    #expect(result[1] == nil)
    #expect(result[2]?.value == "B")
    var arrays = PartialsStream(
      initialValue: StreamArray<ConvertedPartial<PairConversion>>(),
      from: .json()
    )
    try arrays.next("[[1,2],[3,4]]".utf8)
    #expect(try arrays.finish().map { $0.value } == [3, 7])
    var optional = PartialsStream(
      initialValue: Optional<ConvertedPartial<PairConversion>>.none,
      from: .json()
    )
    try optional.next("[1,2]".utf8)
    #expect(try optional.finish()?.value == 3)
  }

  @Test func observerSeesOnlySuccessfulCompletedConversion() throws {
    let chunks = [#"{"text":"h"#, #"i"}"#].map { Array($0.utf8) }
    var iterator = try chunks.partialIterator(of: ConversionModel.self, from: .json())
      .observeField(\.text)
    let first = try iterator.next()
    if case .incomplete(let partial) = first?.value {
      #expect(partial?.value == nil)
    } else {
      Issue.record("Expected incomplete conversion")
    }
    let second = try iterator.next()
    if case .complete(let partial) = second?.value {
      #expect(partial.value == "HI")
    } else {
      Issue.record("Expected completed conversion")
    }
    #expect(try iterator.next()?.isComplete == true)
  }

  @Test func truncatedSourceDoesNotConvertAndResetDiscardsPendingCompletions() throws {
    PairConversion.calls.withLock { $0 = 0 }
    var stream = PartialsStream(initialValue: ConvertedPartial<PairConversion>(), from: .json())
    try stream.next("[1,".utf8)
    #expect(throws: JSONParsingError.self) { _ = try stream.finish() }
    #expect(PairConversion.calls.withLock { $0 } == 0)
    stream.reset()
    try stream.next("[3,4]".utf8)
    #expect(try stream.finish().value == 7)
    #expect(PairConversion.calls.withLock { $0 } == 1)
  }
}

public enum PublicNumberConversion: StreamCompletedValueConversion {
  public typealias Source = Int
  public static func convertToValue(_ source: borrowing Source.View) -> Int { source.value }
  public static func convertFromValue(_ value: Int) -> Int { value }
}
@StreamParseable
public struct PublicConversionModel {
  @StreamParseableMember(completedConversion: PublicNumberConversion.self)
  public var number: Int = 0
}

private enum FixedPairConversion: StreamCompletedValueConversion {
  typealias Source = SIMD2<Int>
  static func convertToValue(_ source: borrowing Source.View) -> Int {
    source.value[0] + source.value[1]
  }
  static func convertFromValue(_ value: Int) -> Source { SIMD2(value, 0) }
}
private enum NestedPairConversion: StreamCompletedValueConversion {
  typealias Source = ConvertedPartial<PairConversion>
  static func convertToValue(_ source: borrowing Source.View) throws(ConversionTestError) -> Int {
    guard let value = source.value else { throw ConversionTestError.invalid }
    return value * 2
  }
  static func convertFromValue(_ value: Int) -> Source { .init(value: value / 2) }
}

extension CompletedValueConversionTests {
  @Test func publicMacroAndFixedSourceArity() throws {
    var publicStream = PartialsStream<PublicConversionModel.Partial>(from: .json())
    try publicStream.next(#"{"number":3}"#.utf8)
    #expect(try publicStream.finish().number?.value == 3)
    for json in ["[1,2]", "[1]", "[1,2,3]"] {
      var stream = PartialsStream(
        initialValue: ConvertedPartial<FixedPairConversion>(),
        from: .json()
      )
      if json == "[1,2]" {
        try stream.next(json.utf8)
        #expect(try stream.finish().value == 3)
      } else {
        #expect(throws: JSONParsingError.self) { try stream.next(json.utf8) }
        #expect(stream.current.value == nil)
      }
    }
  }

  @Test func conversionsSharingContainerBoundaryFinishInsideOut() throws {
    var stream = PartialsStream(
      initialValue: ConvertedPartial<NestedPairConversion>(),
      from: .json()
    )
    try stream.next("[1,2]".utf8)
    let partial = try stream.finish()
    #expect(partial.source.value == 3)
    #expect(partial.value == 6)
  }

  @Test func dictionaryValuesAndOptionalScalarRoots() throws {
    var dictionary = PartialsStream(
      initialValue: StreamDictionary<ConvertedPartial<TextConversion>>(),
      from: .json()
    )
    try dictionary.next(#"{"a":"hello","b":"world","a":"bye"}"#.utf8)
    let result = try dictionary.finish()
    #expect(result["a"]?.value == "BYE")
    #expect(result["b"]?.value == "WORLD")
    var optional = PartialsStream(
      initialValue: Optional<ConvertedPartial<TextConversion>>.none,
      from: .json()
    )
    try optional.next(#""hi""#.utf8)
    #expect(try optional.finish()?.value == "HI")
    optional.reset()
    try optional.next("null".utf8)
    #expect(try optional.finish() == nil)
  }

  @Test func asyncConversionFailureTerminatesCopies() async throws {
    let input = AsyncStream<[UInt8]> { continuation in
      continuation.yield(Array(#"{"text":"bad"}"#.utf8))
      continuation.yield(Array("{}".utf8))
      continuation.finish()
    }
    var iterator = input.partials(of: ConversionModel.self, from: .json()).makeAsyncIterator()
    var copy = iterator
    await #expect(throws: JSONParsingError.self) { _ = try await iterator.next() }
    #expect(try await copy.next() == nil)
    #expect(try await iterator.next() == nil)
  }
}

extension CompletedValueConversionTests {
  @Test func repeatedNumberRetainsAtomicSourceButObservationReportsNewToken() throws {
    let chunks = [#"{"count":2,"#, #""count":1"#, "2}"].map { Array($0.utf8) }
    var stream = PartialsStream<ConversionModel.Partial>(from: .json())
    try stream.next(chunks[0])
    try stream.next(chunks[1])
    // Numbers have no partial typed source updates; the earlier completed value stays cached.
    #expect(stream.current.count?.value == 4)
    try stream.next(chunks[2])
    #expect(try stream.finish().count?.value == 24)

    var observer = try chunks.partialIterator(of: ConversionModel.self, from: .json())
      .observeField(\.count)
    _ = try observer.next()
    let pending = try observer.next()
    if case .incomplete(nil) = pending?.value {
    } else {
      Issue.record("Observation must not expose the earlier conversion as the new token")
    }
  }
}
