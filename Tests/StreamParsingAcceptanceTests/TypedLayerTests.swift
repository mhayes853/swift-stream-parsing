import CustomDump
import Foundation
import StreamParsing
import StreamParsingCore
import Testing

// MARK: - 4. Typed layer
//
// The convenience layer's contract: macro models, conversions back to whole values, enums in the
// wire formats `Codable` uses, optionality, and rejection of what a declaration cannot hold.

@StreamParseable
struct TypedOptionals: Equatable {
  var required: Int
  var optional: Int?
  var label: String?
}

extension TypedOptionals.Partial: Equatable {}

@StreamParseable(partialMembers: .initialValue)
struct TypedInitialValues: Equatable {
  var required: Int
}

@StreamParseable
struct TypedRanges: Equatable {
  var small: Int8
  var unsigned: UInt
  var wide: Int64
  var widest: UInt64
}

@StreamParseable
struct TypedFloats: Equatable {
  var value: Double
}

@StreamParseable
enum TypedStage: String, Equatable {
  @StreamParseableDefault
  case unknown
  case live
  case livestream
}

@StreamParseable
struct TypedTextBlock: Equatable, Codable {
  var body: String
}

@StreamParseable
enum TypedBlock: Equatable, Codable {
  @StreamParseableDefault
  case unknown
  case text(TypedTextBlock)
  case image(url: String, width: Int)
  case pair(Int, label: String)
}

@StreamParseable
struct TypedKeys: Equatable {
  @StreamParseableMember(key: "full_text")
  var text: String
  @StreamParseableMember(keyNames: ["colour", "color"])
  var color: String
  @StreamParseableMember(key: "café")
  var cafe: Int
}

@Suite
struct `Typed layer` {
  // TL-1
  // The strict conversion is the "do I have everything?" question: on a real document it declines
  // through the megabyte before the last required member, and answers with JSONDecoder's value
  // once the document is whole.
  @Test
  func `Strict conversion declines until every required member arrives, then equals JSONDecoder's`()
    throws
  {
    let bytes = try Corpus.llmMessage.bytes
    // `usage` is the last member in the document; nothing before its key can satisfy it.
    let usageKey = Array(#""usage""#.utf8)
    let cutoff = try #require(
      bytes.indices.reversed().first { bytes[$0...].starts(with: usageKey) }
    )
    var stream = PartialsStream<CorpusLLMMessage>(from: .json())
    var declined = 0
    for range in Chunking.variable(seed: 3, maximum: 131_072).ranges(count: cutoff) {
      try stream.next(bytes[range])
      #expect(CorpusLLMMessage(streamPartial: stream.current) == nil)
      declined += 1
    }
    #expect(declined > 10)
    try stream.next(bytes[cutoff...])
    let whole = try stream.finish()
    expectNoDifference(whole, try foundationValue(.llmMessage, as: CorpusLLMMessage.self))
  }

  // TL-2
  // The total conversion keeps what arrived and fills only what did not.
  @Test
  func `Total conversion keeps what arrived and fills the rest with initial values`() throws {
    let partial = try parse(Array(#"{"label":"draft"}"#.utf8), as: TypedOptionals.self)
    #expect(TypedOptionals(streamPartial: partial) == nil)
    expectNoDifference(
      TypedOptionals(orInitial: partial),
      TypedOptionals(required: 0, optional: nil, label: "draft")
    )
  }

  // TL-3
  // `null` and absence are different facts and both are representable. A `null` for a member that
  // cannot be null leaves it absent -- so the strict conversion declines -- and is rejected
  // outright when the partial's members are initial values rather than optionals.
  @Test
  func `Null and absence are distinct, and null never fills a non-optional member`() throws {
    let explicitNull = try parse(
      Array(#"{"required":1,"optional":null}"#.utf8), as: TypedOptionals.self
    )
    let absent = try parse(Array(#"{"required":1}"#.utf8), as: TypedOptionals.self)
    #expect(TypedOptionals(streamPartial: explicitNull) == TypedOptionals(required: 1, optional: nil))
    #expect(TypedOptionals(streamPartial: absent) == TypedOptionals(required: 1, optional: nil))
    #expect(explicitNull.optional == .some(nil))
    #expect(absent.optional == .none)
    let nulled = try parse(
      Array(#"{"required":5,"required":null}"#.utf8), as: TypedOptionals.self
    )
    #expect(nulled.required == nil)
    #expect(TypedOptionals(streamPartial: nulled) == nil)
    expectNoDifference(
      parsingError(Array(#"{"required":null}"#.utf8), as: TypedInitialValues.self)?.reason,
      .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
    )
  }

  // TL-4
  // A token the member cannot hold is rejected at that token, and where is a property of the
  // document: every chunking reports the same byte.
  @Test(arguments: [
    #"{"required":true}"#,
    #"{"required":1,"label":42}"#,
    #"{"required":[1]}"#,
    #"{"required":1,"optional":{"a":1}}"#,
  ])
  func `A type mismatch is rejected at its token under every chunking`(json: String) throws {
    let bytes = Array(json.utf8)
    let error = try #require(parsingError(bytes, as: TypedOptionals.self))
    #expect(error.reason == .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
    for chunking in [Chunking.fixed(1), .fixed(2), .fixed(5), .variable(seed: 1, maximum: 8)] {
      expectNoDifference(
        parsingError(bytes, as: TypedOptionals.self, chunking: chunking), error,
        "\(chunking)"
      )
    }
  }

  // TL-5
  // An out-of-range integer is an error, never a wrapped, truncated, or rounded value.
  @Test(arguments: [
    #"{"small":128,"unsigned":0,"wide":0,"widest":0}"#,
    #"{"small":-129,"unsigned":0,"wide":0,"widest":0}"#,
    #"{"small":0,"unsigned":-1,"wide":0,"widest":0}"#,
    #"{"small":0,"unsigned":0,"wide":9223372036854775808,"widest":0}"#,
    #"{"small":0,"unsigned":0,"wide":0,"widest":18446744073709551616}"#,
    #"{"small":1.5,"unsigned":0,"wide":0,"widest":0}"#,
  ])
  func `An integer the member cannot represent is rejected`(json: String) {
    #expect(parsingError(Array(json.utf8), as: TypedRanges.self) != nil)
  }

  @Test
  func `Integers at the edges of their types are exact`() throws {
    let json = #"""
      {"small":-128,"unsigned":18446744073709551615,"wide":-9223372036854775808,"widest":18446744073709551615}
      """#
    let partial = try parse(Array(json.utf8), as: TypedRanges.self)
    expectNoDifference(
      TypedRanges(streamPartial: partial),
      TypedRanges(small: -128, unsigned: .max, wide: .min, widest: .max)
    )
  }

  // TL-6
  // The decimal-to-binary corner cases that broke real parsers, against the standard library's
  // correctly rounded `Double(String)`, compared by bit pattern so the sign of zero counts.
  @Test(arguments: [
    "0", "-0", "-0.0", "0e10", "1", "-1", "0.1", "0.30000000000000004",
    "9007199254740993",  // 2^53 + 1: rounds to even
    "1.7976931348623157e308",  // largest finite
    "2.2250738585072011e-308",  // the value that hung PHP and Java
    "4.9406564584124654e-324",  // smallest subnormal
    "2.4703282292062328e-324",  // just over half the smallest subnormal: rounds up
    "2.4703282292062327e-324",  // just under: rounds to zero
    "1e23", "8.98846567431158e307", "123456789012345678901234567890",
    "0.000000000000000000000000000001234567890123456789", "1E+2", "1e-2",
  ])
  func `Doubles are correctly rounded`(literal: String) throws {
    let partial = try parse(Array(#"{"value":\#(literal)}"#.utf8), as: TypedFloats.self)
    let expected = try #require(Double(literal))
    #expect(partial.value?.bitPattern == expected.bitPattern, "\(literal)")
  }

  // RFC 8259 numbers have no infinities, so a literal that overflows must not become one.
  @Test
  func `A double that overflows to infinity is rejected`() {
    #expect(parsingError(Array(#"{"value":1e400}"#.utf8), as: TypedFloats.self) != nil)
  }

  // TL-7
  // The README's rule for string-raw enums mid-value: the shortest case the bytes so far are still
  // a prefix of -- which means a case can be superseded as more bytes arrive.
  @Test
  func `A string enum resolves to the shortest case its bytes are still a prefix of`() throws {
    let cases: [(String, TypedStage?)] = [
      ("", nil), ("l", .live), ("liv", .live), ("live", .live), ("lives", .livestream),
      ("livestream", .livestream), ("livid", nil), ("livestreams", nil),
    ]
    for (text, expected) in cases {
      #expect(TypedStage(streamPartial: StreamString(text)) == expected, "\(text.debugDescription)")
    }
    #expect(TypedStage(orInitial: StreamString("livid")) == .unknown)

    // And streamed: the value seen after each byte of `"livestream"`.
    var stream = PartialsStream<TypedStage>(from: .json())
    var seen = [TypedStage?]()
    for byte in #""livestream""#.utf8 {
      try stream.next(byte)
      seen.append(TypedStage(streamPartial: stream.current))
    }
    // The opening quote resolves nothing; "l" through "live" are `.live`; "lives" supersedes it.
    expectNoDifference(
      seen, [nil] + Array(repeating: .live, count: 4) + Array(repeating: .livestream, count: 7)
    )
  }

  // TL-8
  // Enums with associated values read exactly what `JSONEncoder` writes for the same declaration:
  // labeled payloads by label, unlabeled ones as `_0`, `_1`, ... counted over every parameter.
  @Test(arguments: [
    TypedBlock.text(TypedTextBlock(body: "hello")),
    .image(url: "https://example.com/a.png", width: 640),
    .pair(7, label: "seven"),
    .unknown,
  ])
  func `An enum with associated values parses Codable's own encoding`(block: TypedBlock) throws {
    let bytes = try [UInt8](JSONEncoder().encode(block))
    for chunking in [Chunking.whole, .fixed(1)] {
      let partial = try parse(bytes, as: TypedBlock.self, chunking: chunking)
      expectNoDifference(TypedBlock(streamPartial: partial), block, "\(chunking)")
    }
  }

  // TL-9
  // Explicit key names, aliases, and non-ASCII keys all route to their member, bulk and byte-fed.
  @Test(arguments: [Chunking.whole, .fixed(1)])
  func `Explicit keys, aliases, and non-ASCII keys route to their members`(
    chunking: Chunking
  ) throws {
    for (json, color) in [
      (#"{"full_text":"hi","colour":"red","café":1}"#, "red"),
      (#"{"café":1,"color":"blue","full_text":"hi"}"#, "blue"),
    ] {
      let partial = try parse(Array(json.utf8), as: TypedKeys.self, chunking: chunking)
      expectNoDifference(TypedKeys(streamPartial: partial), TypedKeys(text: "hi", color: color, cafe: 1))
    }
    // The Swift name is not a key once a key is named; NFD "café" is a different key from NFC.
    let partial = try parse(
      Array(#"{"text":"no","cafe\#u{301}":2,"full_text":"hi","color":"c","café":1}"#.utf8),
      as: TypedKeys.self, chunking: chunking
    )
    expectNoDifference(TypedKeys(streamPartial: partial), TypedKeys(text: "hi", color: "c", cafe: 1))
  }
}
