import CustomDump
import StreamParsing
import Testing

// `partialStrings: .string` stores a model's `String` leaves as Swift `String`s. Each model is
// checked for its storage by assigning a member to an explicitly typed local, so a lowering that
// fell back to `StreamString` fails to compile rather than passing on equal contents.

@StreamParseable(partialStrings: .string)
private struct StringMessage: Equatable {
  var role: String
  var title: String?
  var tags: [String]
  var headers: [String: String]
  var rows: [[String]]
  var maybe: [String?]
  var grouped: [String: [String]]?
  var count: Int
  @StreamParseableMember(partialStrings: .streamString)
  var transcript: String
  @StreamParseableMember(key: "body_text", initialCapacity: 64)
  var body: String
}

@StreamParseable(partialMembers: .streamInitialValue, partialStrings: .string)
private struct InitialValueStrings: Equatable {
  var name: String
  var tags: [String]
  var note: String?
}

// Opted into per member, with `Swift.String` spelled out.
@StreamParseable
private struct MemberStrings: Equatable {
  @StreamParseableMember(partialStrings: .string)
  var name: Swift.String
  var other: String
}

@StreamParseable(partialStrings: .string)
private enum StringEvent: Equatable {
  @StreamParseableDefault
  case none
  case text(body: String, tags: [String])
  case pair(String, String?)
}

@StreamParseable(partialStrings: .string)
private struct StringPage<Item: StreamParseable & Equatable>: Equatable {
  var title: String
  var items: [Item]
}

@Suite
struct `Partial String Storage Tests` {
  @Test
  func `Members are stored with String leaves`() {
    let partial = StringMessage.Partial()
    let role: String? = partial.role
    let title: String? = partial.title
    let tags: StreamArray<String>? = partial.tags
    let headers: StreamDictionary<String>? = partial.headers
    let rows: StreamArray<StreamArray<String>>? = partial.rows
    let maybe: StreamArray<String?>? = partial.maybe
    let grouped: StreamDictionary<StreamArray<String>>? = partial.grouped
    let count: Int? = partial.count
    let transcript: StreamString? = partial.transcript
    let body: String? = partial.body
    #expect(role == nil && title == nil && tags == nil && headers == nil && rows == nil)
    #expect(maybe == nil && grouped == nil && count == nil && transcript == nil && body == nil)

    let name: String? = MemberStrings.Partial().name
    let other: StreamString? = MemberStrings.Partial().other
    #expect(name == nil && other == nil)
  }

  @Test
  func `A string grows chunk by chunk and snapshots stay put`() throws {
    var stream = PartialsStream(initialValue: StringMessage.Partial(), from: .json())
    try stream.next(Array(#"{"role":"assis"#.utf8))
    let early = stream.current
    expectNoDifference(early.role, "assis")
    try stream.next(Array(#"tant","tags":["a","b"#.utf8))
    expectNoDifference(stream.current.role, "assistant")
    expectNoDifference(stream.current.tags.map(Array.init), ["a", "b"])
    // The snapshot shared the string's buffer; the append copied it rather than writing through.
    expectNoDifference(early.role, "assis")
    expectNoDifference(early.tags, nil)
  }

  @Test
  func `Escapes and multibyte text decode into the String`() throws {
    var stream = PartialsStream(initialValue: StringMessage.Partial(), from: .json())
    try stream.next(Array(#"{"role":"a\nbé\"q\" é 🙂","body_text":"x\ty"}"#.utf8))
    expectNoDifference(stream.current.role, "a\nbé\"q\" é 🙂")
    expectNoDifference(stream.current.body, "x\ty")
  }

  @Test
  func `A document byte by byte converts both ways`() throws {
    let json = #"""
      {"role":"user","title":null,"tags":["x","yz"],"headers":{"k":"v","e":""},
       "rows":[["a"],[],["b","c"]],"maybe":["m",null],"grouped":{"g":["1","2"]},
       "count":7,"transcript":"long","body_text":"hi"}
      """#
    var stream = PartialsStream(initialValue: StringMessage.Partial(), from: .json())
    for byte in json.utf8 { try stream.next(byte) }
    let partial = try stream.finish()
    let expected = StringMessage(
      role: "user", title: nil, tags: ["x", "yz"], headers: ["k": "v", "e": ""],
      rows: [["a"], [], ["b", "c"]], maybe: ["m", nil], grouped: ["g": ["1", "2"]], count: 7,
      transcript: "long", body: "hi"
    )
    expectNoDifference(StringMessage(streamPartial: partial), expected)
    expectNoDifference(StringMessage(streamPartial: expected.streamPartialValue), expected)
    expectNoDifference(StringMessage(orInitial: expected.streamPartialValue), expected)
  }

  @Test
  func `Absent members fail strictly and default totally`() throws {
    var stream = PartialsStream(initialValue: StringMessage.Partial(), from: .json())
    try stream.next(Array(#"{"role":"r","count":1"#.utf8))
    expectNoDifference(StringMessage(streamPartial: stream.current), nil)
    expectNoDifference(
      StringMessage(orInitial: stream.current),
      StringMessage(
        role: "r", title: nil, tags: [], headers: [:], rows: [], maybe: [], grouped: nil,
        count: 0, transcript: "", body: ""
      )
    )
  }

  @Test
  func `Initial value mode starts String members empty`() throws {
    let initial = InitialValueStrings.Partial()
    let name: String = initial.name
    let tags: StreamArray<String> = initial.tags
    let note: String? = initial.note
    #expect(name.isEmpty && tags.isEmpty && note == nil)
    var stream = PartialsStream(initialValue: initial, from: .json())
    try stream.next(Array(#"{"name":"ab","tags":["t"]}"#.utf8))
    expectNoDifference(
      InitialValueStrings(orInitial: try stream.finish()),
      InitialValueStrings(name: "ab", tags: ["t"], note: nil)
    )
  }

  @Test
  func `A member opted in alone parses beside a StreamString`() throws {
    var stream = PartialsStream(initialValue: MemberStrings.Partial(), from: .json())
    try stream.next(Array(#"{"name":"n","other":"o"}"#.utf8))
    expectNoDifference(
      MemberStrings(streamPartial: try stream.finish()), MemberStrings(name: "n", other: "o")
    )
  }

  @Test
  func `Enum payloads store String leaves`() throws {
    let body: String? = StringEvent.TextPayload.Partial().body
    let tags: StreamArray<String>? = StringEvent.TextPayload.Partial().tags
    #expect(body == nil && tags == nil)
    for (json, expected) in [
      (#"{"text":{"body":"hey","tags":["a"]}}"#, StringEvent.text(body: "hey", tags: ["a"])),
      (#"{"pair":{"_0":"l","_1":null}}"#, StringEvent.pair("l", nil)),
    ] {
      var stream = PartialsStream(initialValue: StringEvent.Partial(), from: .json())
      try stream.next(Array(json.utf8))
      let partial = try stream.finish()
      expectNoDifference(StringEvent(streamPartial: partial), expected)
      expectNoDifference(StringEvent(streamPartial: expected.streamPartialValue), expected)
    }
  }

  @Test
  func `A generic struct stores its String leaves`() throws {
    let title: String? = StringPage<Int>.Partial().title
    #expect(title == nil)
    var stream = PartialsStream(initialValue: StringPage<Int>.Partial(), from: .json())
    try stream.next(Array(#"{"title":"p","items":[1,2]}"#.utf8))
    expectNoDifference(
      StringPage(streamPartial: try stream.finish()), StringPage(title: "p", items: [1, 2])
    )
  }

  @Test
  func `Multibyte text fed byte by byte reassembles whole scalars`() throws {
    // The parser holds an incomplete sequence back until it completes, so every append is whole
    // UTF-8: no replacement characters at the cuts.
    var stream = PartialsStream(initialValue: StringMessage.Partial(), from: .json())
    let json = #"{"role":"é🙂 ñ \u00e9 中文","body_text":"x"}"#
    var seen: [String] = []
    for byte in json.utf8 {
      try stream.next(byte)
      if let role = stream.current.role { seen.append(role) }
    }
    expectNoDifference(stream.current.role, "é🙂 ñ é 中文")
    #expect(seen.allSatisfy { !$0.unicodeScalars.contains("\u{FFFD}") })
  }

  @Test
  func `A direct append of ill-formed bytes is repaired, not trusted`() {
    func appended(_ start: String, _ bytes: [UInt8]) -> String {
      var value = start
      bytes.withUnsafeBufferPointer { value.streamAppend(utf8: Span(_unsafeElements: $0)) }
      return value
    }
    expectNoDifference(appended("a", Array("bé🙂".utf8)), "abé🙂")
    expectNoDifference(appended("a", []), "a")
    expectNoDifference(appended("a", [0xFF, 0x62]), "a\u{FFFD}b")
    // A sequence cut at the end of the bytes.
    expectNoDifference(appended("a", [0x62, 0xF0, 0x9F]), "ab\u{FFFD}")
    // An overlong encoding and a surrogate, both well-formed in shape only.
    expectNoDifference(appended("", [0xC0, 0xAF]).unicodeScalars.allSatisfy { $0 == "\u{FFFD}" }, true)
    expectNoDifference(appended("", [0xED, 0xA0, 0x80]).unicodeScalars.allSatisfy { $0 == "\u{FFFD}" }, true)
    // From 32 bytes: all ASCII copies in unchecked; one stray byte at the end still repairs.
    let ascii = Array(String(repeating: "abcdefgh", count: 5).utf8)
    expectNoDifference(appended("x", ascii), "x" + String(repeating: "abcdefgh", count: 5))
    expectNoDifference(appended("", ascii + [0xFF]), String(repeating: "abcdefgh", count: 5) + "\u{FFFD}")
    expectNoDifference(appended("", ascii + [0xE4, 0xB8]), String(repeating: "abcdefgh", count: 5) + "\u{FFFD}")
    // Long enough to take the validator's block loop rather than its short tail.
    let long = Array(String(repeating: "abcdefghé", count: 20).utf8)
    expectNoDifference(appended("", long), String(repeating: "abcdefghé", count: 20))
    expectNoDifference(appended("", long + [0xFF]), String(repeating: "abcdefghé", count: 20) + "\u{FFFD}")
  }

  @Test
  func `A number where a String member is expected is a type mismatch`() {
    var stream = PartialsStream(initialValue: StringMessage.Partial(), from: .json())
    #expect(throws: (any Error).self) {
      try stream.next(Array(#"{"role":5}"#.utf8))
    }
  }
}
