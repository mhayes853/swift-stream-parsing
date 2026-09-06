import CustomDump
import Foundation
import StreamParsing
import Testing

// `@StreamParseable` on an enum, in the three lowerings it picks from how the enum is spelled.
// Each one is checked against what `JSONEncoder`/`JSONDecoder` do with the same declaration,
// because matching `Codable`'s wire format is the whole reason the raw-less form is an object.

// MARK: - Declarations

@StreamParseable
private enum Stage: String, Codable, Equatable {
  @StreamParseableDefault
  case unknown
  case live
}

// `live` is a prefix of `livestream`, which is the case the resolution rule exists for.
@StreamParseable
private enum Broadcast: String, Equatable {
  @StreamParseableDefault
  case live
  case livestream
  case livestreaming
}

@StreamParseable
private enum Renamed: String, Equatable {
  @StreamParseableDefault
  case notStarted = "not_started"
  case inProgress = "in_progress"
  // Long enough to need a second word in the matcher's `where` clause.
  case awaitingModeration = "awaiting_moderation"
}

@StreamParseable
private enum Aliased: String, Equatable {
  @StreamParseableDefault
  @StreamParseableMember(keyNames: ["LIVE", "running"])
  case live
  case idle
}

// An empty raw value is a real sentinel, and it is the one case where zero accumulated bytes are
// a value rather than an absence.
@StreamParseable
private enum Sentinel: String, Equatable {
  @StreamParseableDefault
  case none = ""
  case some = "s"
}

@StreamParseable
private enum Priority: Int, Equatable {
  @StreamParseableDefault
  case low = 0
  case high = 10
}

@StreamParseable
private enum Figure: Codable, Equatable {
  @StreamParseableDefault
  case circle
  case square
}

@StreamParseable
private struct Job: Equatable {
  var stage: Stage
  var priority: Priority
  var figure: Figure
}

// MARK: - Helpers

private func parsePartial<T: StreamParseable>(
  _ json: String,
  as type: T.Type
) throws -> T.Partial {
  var stream = PartialsStream(initialValue: T.Partial.streamInitialValue(), from: .json())
  for byte in Array(json.utf8) {
    try stream.next(byte)
  }
  return stream.current
}

// Feeds a bare string value one byte at a time, handing back the enum resolved after each
// content byte. This is the only way to see the prefix rule act, since it is exactly the
// mid-value read that a completed parse never exposes.
private func resolutions<T: StreamParseable>(
  streamingRawValue rawValue: String,
  as type: T.Type
) throws -> [T?] where T.Partial == StreamString {
  var stream = PartialsStream(initialValue: StreamString(), from: .json())
  var results = [T?]()
  try stream.next(UInt8(ascii: "\""))
  for byte in Array(rawValue.utf8) {
    try stream.next(byte)
    results.append(T(streamPartial: stream.current))
  }
  return results
}

@Suite
struct `Enum Parseable Tests` {

  // MARK: - String raw values

  @Test
  func `Resolves a complete raw value`() throws {
    let partial = try parsePartial(#"{"stage":"live"}"#, as: Job.self)
    expectNoDifference(partial.stage.flatMap(Stage.init(streamPartial:)), .live)
  }

  @Test
  func `Declines a raw value no case declares`() throws {
    let partial = try parsePartial(#"{"stage":"retired"}"#, as: Job.self)
    expectNoDifference(partial.stage.flatMap(Stage.init(streamPartial:)), nil)
  }

  // The long-unknown-value case: with bounded storage this would have been a parse failure, and
  // with `StreamString` it is what it should be — a value the type cannot represent.
  @Test
  func `Declines a raw value longer than every case`() throws {
    let partial = try parsePartial(#"{"stage":"live_streaming_right_now_and_for_a_long_while"}"#, as: Job.self)
    expectNoDifference(partial.stage.flatMap(Stage.init(streamPartial:)), nil)
  }

  @Test
  func `Reads explicit raw values, including past the first word`() throws {
    expectNoDifference(Renamed(streamPartial: StreamString("not_started")), .notStarted)
    expectNoDifference(Renamed(streamPartial: StreamString("in_progress")), .inProgress)
    expectNoDifference(Renamed(streamPartial: StreamString("awaiting_moderation")), .awaitingModeration)
    // Shares its first eight bytes with `awaiting_moderation` and differs in the second word.
    expectNoDifference(Renamed(streamPartial: StreamString("awaiting_review")), nil)
  }

  // Aliases are additive for a `String`-raw enum: the raw value is what the type emits, so it
  // has to stay something the type accepts even when the attribute never mentions it.
  @Test
  func `Accepts every alias alongside the raw value it emits`() throws {
    expectNoDifference(Aliased(streamPartial: StreamString("live")), .live)
    expectNoDifference(Aliased(streamPartial: StreamString("LIVE")), .live)
    expectNoDifference(Aliased(streamPartial: StreamString("running")), .live)
    expectNoDifference(String(Aliased.live.streamPartialValue), "live")
    expectNoDifference(Aliased(streamPartial: Aliased.live.streamPartialValue), .live)
  }

  // MARK: - Prefix resolution

  @Test
  func `An empty accumulation declines rather than guessing`() throws {
    expectNoDifference(Stage(streamPartial: StreamString()), nil)
    expectNoDifference(Broadcast(streamPartial: StreamString()), nil)
  }

  // The documented rule, and the reason it is a rule: at four bytes the value is `live` and is
  // also still on its way to `livestream`, and nothing in the partial can say which. The shortest
  // case consistent with the bytes wins, so a case can be superseded rather than merely filled in.
  @Test
  func `Resolves to the shortest case still consistent with the bytes`() throws {
    expectNoDifference(
      try resolutions(streamingRawValue: "livestreaming", as: Broadcast.self),
      [
        .live,          // l          -> a prefix of all three; live is the shortest
        .live,          // li
        .live,          // liv
        .live,          // live       -> exact
        .livestream,    // lives      -> no longer consistent with live
        .livestream,    // livest
        .livestream,    // livestr
        .livestream,    // livestre
        .livestream,    // livestrea
        .livestream,    // livestream -> exact
        .livestreaming, // livestreami
        .livestreaming, // livestreamin
        .livestreaming  // livestreaming -> exact
      ]
    )
  }

  @Test
  func `A value that leaves every case declines again`() throws {
    expectNoDifference(
      try resolutions(streamingRawValue: "livid", as: Broadcast.self),
      [.live, .live, .live, nil, nil]
    )
  }

  @Test
  func `An empty raw value is a case rather than an absence`() throws {
    expectNoDifference(Sentinel(streamPartial: StreamString()), Sentinel.none)
    expectNoDifference(Sentinel(streamPartial: StreamString("s")), Sentinel.some)
    expectNoDifference(Sentinel(streamPartial: StreamString("x")), nil)
  }

  // MARK: - Integer raw values

  @Test
  func `Resolves an integer raw value`() throws {
    let partial = try parsePartial(#"{"priority":10}"#, as: Job.self)
    expectNoDifference(partial.priority.flatMap(Priority.init(streamPartial:)), .high)
  }

  @Test
  func `Declines an integer raw value no case declares`() throws {
    let partial = try parsePartial(#"{"priority":7}"#, as: Job.self)
    expectNoDifference(partial.priority.flatMap(Priority.init(streamPartial:)), nil)
  }

  // MARK: - Raw-less enums

  @Test
  func `Resolves the case-name-keyed object form`() throws {
    let partial = try parsePartial(#"{"figure":{"square":{}}}"#, as: Job.self)
    expectNoDifference(partial.figure.flatMap(Figure.init(streamPartial:)), .square)
  }

  @Test
  func `Declines an object naming no case, or naming two`() throws {
    expectNoDifference(Figure(streamPartial: Figure.Partial()), nil)
    expectNoDifference(
      Figure(streamPartial: Figure.Partial(circle: StreamEmptyObject(), square: StreamEmptyObject())),
      nil
    )
  }

  // The whole point of matching `Codable`: a document `JSONDecoder` accepts parses the same way
  // here, and one it rejects declines here.
  @Test(arguments: [#"{"square":{}}"#, #"{"circle":{}}"#])
  func `Agrees with JSONDecoder on the object form`(json: String) throws {
    let decoded = try JSONDecoder().decode(Figure.self, from: Data(json.utf8))
    let partial = try parsePartial(json, as: Figure.self)
    expectNoDifference(Figure(streamPartial: partial), decoded)
  }

  @Test(arguments: [#"{}"#, #"{"circle":{},"square":{}}"#, #"{"bogus":{}}"#])
  func `Declines every object form JSONDecoder rejects`(json: String) throws {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(Figure.self, from: Data(json.utf8))
    }
    let partial = try parsePartial(json, as: Figure.self)
    expectNoDifference(Figure(streamPartial: partial), nil)
  }

  @Test(arguments: [#"{"square":5}"#, #"{"square":[]}"#, #"{"square":"x"}"#])
  func `Declines a case payload that is not an object`(json: String) throws {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(Figure.self, from: Data(json.utf8))
    }
    var stream = PartialsStream(initialValue: Figure.Partial(), from: .json())
    #expect(throws: (any Error).self) {
      for byte in Array(json.utf8) {
        try stream.next(byte)
      }
    }
  }

  // Every lowering has to read the same however the bytes are split, which for the `String`-raw
  // one is the whole risk surface: it is the only partial assembled across chunks.
  @Test(arguments: [
    #"{"stage":"live","priority":10,"figure":{"square":{}}}"#,
    #"{"stage":"unknown","priority":0,"figure":{"circle":{}}}"#
  ])
  func `Reads the same at every chunk size`(json: String) throws {
    let bytes = Array(json.utf8)
    let whole = try parsePartial(json, as: Job.self)
    let expected = Job(orInitial: whole)
    for size in 1...bytes.count {
      var stream = PartialsStream(initialValue: Job.Partial(), from: .json())
      var index = 0
      while index < bytes.count {
        let end = min(index + size, bytes.count)
        try stream.next(bytes[index..<end])
        index = end
      }
      expectNoDifference(Job(orInitial: stream.current), expected)
    }
  }

  @Test
  func `Agrees with JSONEncoder on the object form`() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    expectNoDifference(String(decoding: try encoder.encode(Figure.square), as: UTF8.self), #"{"square":{}}"#)
    expectNoDifference(String(decoding: try encoder.encode(Stage.live), as: UTF8.self), #""live""#)
  }

  // MARK: - Defaults

  // The strict conversion declines and the total one substitutes: the two exist to say different
  // things, and naming a default must not collapse them.
  @Test
  func `The default case fills only the total conversion`() throws {
    expectNoDifference(Stage(streamPartial: StreamString("retired")), nil)
    expectNoDifference(Stage.streamValueOrInitial(from: StreamString("retired")), .unknown)
    expectNoDifference(Priority.streamValueOrInitial(from: 7), .low)
    expectNoDifference(Figure.streamValueOrInitial(from: Figure.Partial()), .circle)
  }

  @Test
  func `A struct holding enums fills its absent members from their defaults`() throws {
    let partial = try parsePartial(#"{"stage":"live"}"#, as: Job.self)
    expectNoDifference(Job(orInitial: partial), Job(stage: .live, priority: .low, figure: .circle))
    expectNoDifference(Job(streamPartial: partial), nil)
  }

  // MARK: - Round trips

  @Test
  func `Round trips through the partial`() throws {
    expectNoDifference(Stage(streamPartial: Stage.live.streamPartialValue), .live)
    expectNoDifference(Priority(streamPartial: Priority.high.streamPartialValue), .high)
    expectNoDifference(Figure(streamPartial: Figure.square.streamPartialValue), .square)
  }
}

// MARK: - StreamString word access

@Suite
struct `Stream String Word Tests` {
  @Test
  func `Pads past the accumulated bytes`() {
    expectNoDifference(StreamString("ab").paddedLeadingWord(), 0x0000_0000_0000_6261)
    expectNoDifference(StreamString().paddedLeadingWord(), 0)
    expectNoDifference(StreamString("abcdefgh").paddedLeadingWord(), 0x6867_6665_6463_6261)
  }

  @Test
  func `Reads the second word and past the end`() {
    let value = StreamString("abcdefghij")
    expectNoDifference(value.paddedWord(at: 8), 0x0000_0000_0000_6A69)
    expectNoDifference(value.paddedWord(at: 16), 0)
  }

  // Crosses out of the 64-byte inline buffer into block storage, where the words come from a
  // different representation and have to read the same.
  @Test
  func `Reads promoted storage identically`() {
    let value = StreamString(String(repeating: "abcdefgh", count: 12))
    expectNoDifference(value.utf8Count, 96)
    expectNoDifference(value.paddedLeadingWord(), 0x6867_6665_6463_6261)
    expectNoDifference(value.paddedWord(at: 88), 0x6867_6665_6463_6261)
  }

  @Test
  func `Answers the prefix question in the streaming direction`() {
    expectNoDifference(StreamString("liv").isPrefix(of: "livestream"), true)
    expectNoDifference(StreamString("livestream").isPrefix(of: "livestream"), true)
    expectNoDifference(StreamString("livestreams").isPrefix(of: "livestream"), false)
    expectNoDifference(StreamString("x").isPrefix(of: "livestream"), false)
    expectNoDifference(StreamString().isPrefix(of: "livestream"), true)
  }
}
