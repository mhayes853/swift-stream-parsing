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

// MARK: - Associated values

@StreamParseable
private struct TextBlock: Codable, Equatable {
  var body: String
}

// A mix of no-payload, single-unlabeled-payload, and multi-labeled-payload cases, exactly the
// three shapes `Codable`'s own synthesis distinguishes.
@StreamParseable
private enum Block: Codable, Equatable {
  @StreamParseableDefault
  case unknown
  case text(TextBlock)
  case image(url: String, width: Int)
}

// The default case itself carries a payload, so the total conversion has to fill it from its
// own field's initial value rather than naming a bare case.
@StreamParseable
private enum Note: Codable, Equatable {
  case text(String)
  @StreamParseableDefault
  case empty(reason: String)
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

  // MARK: - Associated values

  @Test
  func `Reads a single unlabeled payload`() throws {
    let partial = try parsePartial(#"{"text":{"_0":{"body":"hi"}}}"#, as: Block.self)
    expectNoDifference(Block(streamPartial: partial), .text(TextBlock(body: "hi")))
  }

  @Test
  func `Reads multiple labeled payloads`() throws {
    let partial = try parsePartial(#"{"image":{"url":"u","width":3}}"#, as: Block.self)
    expectNoDifference(Block(streamPartial: partial), .image(url: "u", width: 3))
  }

  @Test
  func `Resolves a no-payload case alongside payload-bearing ones`() throws {
    let partial = try parsePartial(#"{"unknown":{}}"#, as: Block.self)
    expectNoDifference(Block(streamPartial: partial), .unknown)
  }

  @Test
  func `Declines a payload that has not fully arrived`() throws {
    let partial = try parsePartial(#"{"image":{"url":"u"}}"#, as: Block.self)
    expectNoDifference(Block(streamPartial: partial), nil)
  }

  @Test
  func `Declines two case keys naming associated-value cases`() throws {
    let partial = try parsePartial(#"{"text":{"_0":{"body":"hi"}},"unknown":{}}"#, as: Block.self)
    expectNoDifference(Block(streamPartial: partial), nil)
  }

  @Test
  func `A payload-bearing default case fills from its own fields' initial values`() throws {
    expectNoDifference(Note.streamValueOrInitial(from: Note.Partial()), .empty(reason: ""))
    let partial = try parsePartial(#"{"empty":{}}"#, as: Note.self)
    expectNoDifference(Note.streamValueOrInitial(from: partial), .empty(reason: ""))
    expectNoDifference(Note(streamPartial: partial), nil)
  }

  @Test(arguments: [
    #"{"unknown":{}}"#, #"{"text":{"_0":{"body":"hi"}}}"#, #"{"image":{"url":"u","width":3}}"#
  ])
  func `Agrees with JSONDecoder on associated-value shapes`(json: String) throws {
    let decoded = try JSONDecoder().decode(Block.self, from: Data(json.utf8))
    let partial = try parsePartial(json, as: Block.self)
    expectNoDifference(Block(streamPartial: partial), decoded)
  }

  @Test
  func `Agrees with JSONEncoder on associated-value shapes`() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    expectNoDifference(
      String(decoding: try encoder.encode(Block.text(TextBlock(body: "hi"))), as: UTF8.self),
      #"{"text":{"_0":{"body":"hi"}}}"#
    )
    expectNoDifference(
      String(decoding: try encoder.encode(Block.image(url: "u", width: 3)), as: UTF8.self),
      #"{"image":{"url":"u","width":3}}"#
    )
  }

  @Test
  func `Round trips an associated-value case through the partial`() throws {
    expectNoDifference(Block(streamPartial: Block.text(TextBlock(body: "hi")).streamPartialValue), .text(TextBlock(body: "hi")))
    expectNoDifference(
      Block(streamPartial: Block.image(url: "u", width: 3).streamPartialValue),
      .image(url: "u", width: 3)
    )
  }

  // Every lowering has to read the same however the bytes are split — associated values add a
  // second frame (the payload's own object) that the sink has to route into correctly no matter
  // where the split lands.
  @Test(arguments: [
    #"{"text":{"_0":{"body":"hi"}}}"#,
    #"{"image":{"url":"u","width":3}}"#
  ])
  func `Reads an associated-value case the same at every chunk size`(json: String) throws {
    let bytes = Array(json.utf8)
    let whole = try parsePartial(json, as: Block.self)
    let expected = Block(streamPartial: whole)
    for size in 1...bytes.count {
      var stream = PartialsStream(initialValue: Block.Partial(), from: .json())
      var index = 0
      while index < bytes.count {
        let end = min(index + size, bytes.count)
        try stream.next(bytes[index..<end])
        index = end
      }
      expectNoDifference(Block(streamPartial: stream.current), expected)
    }
  }

  // MARK: - Resolved view

  private func blockStream(_ json: String) throws -> PartialsStream<Block.Partial> {
    var stream = PartialsStream(initialValue: Block.Partial(), from: .json())
    try stream.next(Array(json.utf8))
    return stream
  }

  @Test
  func `Reads a payload case's view mid-stream`() throws {
    let stream = try self.blockStream(#"{"image":{"url":"u","width":3}}"#)
    stream.withView { partial in
      switch partial.resolved {
      case .image(let view):
        guard let urlView = view.url, let widthView = view.width else {
          Issue.record("expected populated url/width views")
          return
        }
        expectNoDifference(String(streamPartial: urlView.value), "u")
        expectNoDifference(widthView.value, 3)
      default:
        Issue.record("expected .image")
      }
    }
  }

  @Test
  func `Reads a no-payload case's view`() throws {
    let stream = try self.blockStream(#"{"unknown":{}}"#)
    stream.withView { partial in
      switch partial.resolved {
      case .unknown: break
      default: Issue.record("expected .unknown")
      }
    }
  }

  @Test
  func `The view is unresolved before any key arrives, and ambiguous after two`() throws {
    let empty = PartialsStream(initialValue: Block.Partial(), from: .json())
    empty.withView { partial in
      switch partial.resolved {
      case .unresolved: break
      default: Issue.record("expected .unresolved")
      }
    }
    let stream = try self.blockStream(#"{"text":{"_0":{"body":"hi"}},"unknown":{}}"#)
    stream.withView { partial in
      switch partial.resolved {
      case .ambiguous: break
      default: Issue.record("expected .ambiguous")
      }
    }
  }
}

// MARK: - Wide enums

// Nine cases, so the resolution is the stored discriminator's rather than a count over every
// member. The oracle below is that count, read through the public members.
@StreamParseable
private enum Wide: Codable, Equatable {
  @StreamParseableDefault
  case c0
  case c1
  case c2
  case c3
  case c4
  case c5
  case c6
  case c7(label: String)
  case c8(Int)

  static let names = ["c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7", "c8"]

  var name: String {
    switch self {
    case .c0: "c0"
    case .c1: "c1"
    case .c2: "c2"
    case .c3: "c3"
    case .c4: "c4"
    case .c5: "c5"
    case .c6: "c6"
    case .c7: "c7"
    case .c8: "c8"
    }
  }
}

@StreamParseable
private struct WideDocument: Codable, Equatable {
  var values: [Wide]
}

// What resolution meant before the discriminator: count the members that are present.
private func countedName(_ partial: Wide.Partial) -> String {
  let present = [
    partial.c0 != nil, partial.c1 != nil, partial.c2 != nil, partial.c3 != nil, partial.c4 != nil,
    partial.c5 != nil, partial.c6 != nil, partial.c7 != nil, partial.c8 != nil
  ]
  let hits = present.indices.filter { present[$0] }
  switch hits.count {
  case 0: return "unresolved"
  case 1: return Wide.names[hits[0]]
  default: return "ambiguous"
  }
}

private func resolvedName(_ partial: borrowing Wide.Partial.View) -> String {
  switch partial.resolved {
  case .unresolved: "unresolved"
  case .ambiguous: "ambiguous"
  case .c0: "c0"
  case .c1: "c1"
  case .c2: "c2"
  case .c3: "c3"
  case .c4: "c4"
  case .c5: "c5"
  case .c6: "c6"
  case .c7: "c7"
  case .c8: "c8"
  }
}

// The conversion agrees with the count: nil unless one case is present, that case when it has no
// payload, and that case or nil (an incomplete payload) when it has one.
private func expectResolution(_ partial: Wide.Partial, sourceLocation: SourceLocation = #_sourceLocation) {
  let expected = countedName(partial)
  let converted = Wide(streamPartial: partial)
  switch expected {
  case "unresolved", "ambiguous":
    #expect(converted == nil, "\(expected)", sourceLocation: sourceLocation)
  case "c7", "c8":
    #expect(converted == nil || converted?.name == expected, sourceLocation: sourceLocation)
  default:
    #expect(converted?.name == expected, sourceLocation: sourceLocation)
  }
}

@Suite
struct `Wide Enum Tests` {
  private static let document = #"""
    {"values":[{"c3":{}},{"c7":{"label":"x"}},{"c0":{}},{"c8":{"_0":5}},{"c6":{}},{"c1":{}},\#
    {"c5":{}},{"c2":{}},{"c4":{}},{"c7":{"label":"yz"}},{"c3":{}}]}
    """#

  @Test
  func `Resolves every case of an array at every chunk size`() throws {
    let bytes = Array(Self.document.utf8)
    let expected = try JSONDecoder().decode(WideDocument.self, from: Data(bytes))
    for size in 1...bytes.count {
      var stream = PartialsStream(initialValue: WideDocument.Partial(), from: .json())
      var index = 0
      while index < bytes.count {
        let end = min(index + size, bytes.count)
        try stream.next(bytes[index..<end])
        index = end
        // The open element is the one whose case may have just switched.
        if let open = stream.current.values?.last { expectResolution(open) }
      }
      expectNoDifference(WideDocument(streamPartial: stream.current), expected)
    }
  }

  // Two keys in one object, a `null`, and a repeated key: the discriminator either names the one
  // present case or hands back to the count, and must agree with it after every chunk.
  @Test(arguments: [
    #"{"c1":{},"c2":{}}"#,
    #"{"c1":null,"c2":{}}"#,
    #"{"c1":{},"c1":null,"c2":{}}"#,
    #"{"c2":{},"c2":null}"#,
    #"{"c7":{"label":"a"},"c7":{"label":"b"}}"#,
    #"{"c8":{"_0":1},"c0":{},"c0":null}"#,
    #"{"c4":{},"c5":{},"c4":null,"c5":null,"c6":{}}"#
  ])
  func `Agrees with the member count after every chunk`(json: String) throws {
    let bytes = Array(json.utf8)
    for size in 1...bytes.count {
      var stream = PartialsStream(initialValue: Wide.Partial(), from: .json())
      var index = 0
      while index < bytes.count {
        let end = min(index + size, bytes.count)
        try stream.next(bytes[index..<end])
        index = end
        let counted = countedName(stream.current)
        stream.withView { expectNoDifference(resolvedName($0), counted) }
        expectResolution(stream.current)
      }
    }
  }

  @Test
  func `Tracks writes made through the members`() {
    var partial = Wide.Partial()
    expectNoDifference(Wide(streamPartial: partial), nil)
    partial.c5 = StreamEmptyObject()
    expectNoDifference(Wide(streamPartial: partial), .c5)
    partial.c6 = StreamEmptyObject()
    expectNoDifference(Wide(streamPartial: partial), nil)
    partial.c5 = nil
    expectNoDifference(Wide(streamPartial: partial), .c6)
    partial.c6 = nil
    expectNoDifference(Wide(streamPartial: partial), nil)
    partial.c0 = StreamEmptyObject()
    expectNoDifference(Wide(streamPartial: partial), .c0)
    expectNoDifference(Wide(streamPartial: Wide.Partial(c1: StreamEmptyObject(), c4: StreamEmptyObject())), nil)
    expectNoDifference(Wide(streamPartial: Wide.Partial(c4: StreamEmptyObject())), .c4)
    expectNoDifference(Wide(streamPartial: Wide.c8(3).streamPartialValue), .c8(3))
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
