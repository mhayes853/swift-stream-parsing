import CustomDump
import Foundation
import Testing

import StreamParsingCore

// The windowed path's one contract: a sink cannot tell which path parsed a document. Every
// document here is parsed byte by byte through the dispatcher, then in bulk and in several
// chunkings with the window threshold forced to one byte, and the recorded event streams —
// every event, every span's bytes, every number's info, and the error if any — must be
// identical. A rejecting sink checks the same for where a rejection surfaces.
@Suite
struct `Windowed parser tests` {
  enum Event: Equatable {
    case beginObject, endObject, beginArray, endArray
    case key([UInt8])
    case stringBegin, stringChunk([UInt8]), stringEnd
    case number([UInt8], NumberInfo)
    case boolean(Bool), null
  }

  struct RecordingSink: StreamParseSink {
    var events: [Event] = []
    var streamFailure: StreamSinkFailure?
    var rejecting: Set<String> = []

    private mutating func record(_ event: Event, kind: String) {
      self.events.append(event)
      if self.rejecting.contains(kind), self.streamFailure == nil {
        self.streamFailure = StreamSinkFailure(reason: .typeMismatch)
      }
    }

    mutating func beginObject() { self.record(.beginObject, kind: "object") }
    mutating func endObject() { self.record(.endObject, kind: "endObject") }
    mutating func beginArray() { self.record(.beginArray, kind: "array") }
    mutating func endArray() { self.record(.endArray, kind: "endArray") }
    private static func copy(_ span: Span<UInt8>) -> [UInt8] {
      var out = [UInt8]()
      out.reserveCapacity(span.count)
      for i in span.indices { out.append(span[i]) }
      return out
    }

    mutating func key(_ bytes: Span<UInt8>) { self.record(.key(Self.copy(bytes)), kind: "key") }
    mutating func stringBegin() { self.record(.stringBegin, kind: "stringBegin") }
    mutating func stringChunk(_ bytes: Span<UInt8>) {
      self.record(.stringChunk(Self.copy(bytes)), kind: "stringChunk")
    }
    mutating func stringEnd() { self.record(.stringEnd, kind: "stringEnd") }
    mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
      self.record(.number(Self.copy(bytes), info), kind: "number")
    }
    mutating func boolean(_ value: Bool) { self.record(.boolean(value), kind: "boolean") }
    mutating func null() { self.record(.null, kind: "null") }
  }

  struct Outcome: Equatable {
    var events: [Event]
    var error: JSONParsingError?
  }

  static func run(
    _ bytes: [UInt8], chunk: Int, windowThreshold: Int, rejecting: Set<String> = []
  ) -> Outcome {
    var parser = JSONParser(windowThreshold: windowThreshold)
    var sink = RecordingSink()
    sink.rejecting = rejecting
    var error: JSONParsingError?
    do {
      try bytes.withUnsafeBufferPointer { buffer throws(JSONParsingError) in
        var offset = 0
        while offset < buffer.count {
          let count = min(chunk, buffer.count - offset)
          try parser.parse(
            UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: count), into: &sink
          )
          offset += count
        }
      }
      try parser.finish(into: &sink)
    } catch let caught as JSONParsingError {
      error = caught
    } catch let caught {
      Issue.record("Unexpected error type: \(caught)")
    }
    return Outcome(events: sink.events, error: error)
  }

  // The oracle is the dispatcher fed the *same* chunking: string chunk boundaries legitimately
  // follow the feed (byte by byte emits one chunk per byte), so a byte fed run is not the
  // reference for a bulk one. Within one chunking the two paths must agree exactly.
  static func expectEquivalent(_ bytes: [UInt8], _ label: String, rejecting: Set<String> = []) {
    for chunk in [Int.max, 64, 100, 1000, 32_768, 40_000] {
      let dispatcher = Self.run(bytes, chunk: chunk, windowThreshold: .max, rejecting: rejecting)
      let windowed = Self.run(bytes, chunk: chunk, windowThreshold: 1, rejecting: rejecting)
      guard windowed != dispatcher else { continue }
      // A whole-stream diff of a large document is quadratic; name the first divergence.
      let at = zip(windowed.events, dispatcher.events).enumerated().first { $1.0 != $1.1 }?.offset
        ?? min(windowed.events.count, dispatcher.events.count)
      let lo = max(0, at - 3)
      Issue.record(
        """
        \(label): chunk \(chunk) diverges at event \(at) \
        (\(windowed.events.count) vs \(dispatcher.events.count) events; \
        errors \(String(describing: windowed.error)) vs \(String(describing: dispatcher.error)))
        windowed:   \(Array(windowed.events[lo..<min(at + 3, windowed.events.count)]))
        dispatcher: \(Array(dispatcher.events[lo..<min(at + 3, dispatcher.events.count)]))
        """
      )
    }
  }

  // MARK: - Documents

  static let documents: [(String, String)] = [
    ("empty object", "{}"),
    ("empty array", "[]"),
    ("scalar root", "42"),
    ("string root", #""hello""#),
    ("literal roots", "true"),
    ("null root", "null"),
    ("flat", #"{"id":4,"name":"Blob","score":98.25,"active":true,"none":null}"#),
    ("pretty", "{\n  \"a\" : [ 1 , 2 , 3 ] ,\n\t\"b\" : { \"c\" : \"d\" }\n}\n"),
    ("nested", #"{"a":{"b":{"c":[[[]],[{}],[1,[2,[3]]]]}}}"#),
    ("numbers", #"[0,-0,1,-1,12345678,123456789,1234567890123456789,12345678901234567890,1.5,-1.5e10,1E-2,0.000001,1e400,3.141592653589793238462643383279]"#),
    ("escapes", #"{"t":"a\nb\tc\"d\\e\/f\bg\fh\ri"}"#),
    ("unicode escapes", #"["\u0041\u00e9\u20ac\ud83d\ude00", "\u0000"]"#),
    ("escape at start of key", #"{"\nkey":1,"\u0041":2}"#),
    ("non-ascii", #"{"é":"Aé€😀","😀":"😀"}"#),
    ("long ascii string", "[\"" + String(repeating: "abcdefgh", count: 300) + "\"]"),
    ("long string with escape", "[\"" + String(repeating: "abcdefgh", count: 300) + "\\n\"]"),
    ("long non-ascii string", "[\"" + String(repeating: "é€😀", count: 300) + "\"]"),
    ("many small", "[" + (0..<2000).map { "{\"k\(($0)):\":\($0)}" }.joined(separator: ",") + "]"),
    ("array of strings", "[" + (0..<3000).map { "\"s\($0)\"" }.joined(separator: ",") + "]"),
    ("whitespace between everything", " [ 1 , \"a\" , true , { \"k\" : null } ] "),
    ("string longer than a window", "[\"" + String(repeating: "x", count: 40_000) + "\",1]"),
    ("number at window boundary", "[" + String(repeating: "1,", count: 16_383) + "1234567890]"),
    // Errors: every reason the dispatcher can report, at a position the walk has to match.
    ("trailing content", "{} x"),
    ("trailing comma", "[1,]"),
    ("bare garbage", "[1x]"),
    ("garbage after literal", "[truex]"),
    ("garbage after literal 2", "[true1]"),
    ("bad literal", "[trux]"),
    ("cut literal", "[tru"),
    ("bad number", "[1e]"),
    ("bad number 2", "[-]"),
    ("bad number 3", "[01]"),
    ("bad number 4", "[1.]"),
    ("number then quote", "[1\"a\"]"),
    ("two scalars", "[1 2]"),
    ("missing colon", #"{"a" 1}"#),
    ("missing value", #"{"a":}"#),
    ("key not string", "{1:2}"),
    ("mismatched close", "[1}"),
    ("mismatched close 2", #"{"a":1]"#),
    ("close at root", "]"),
    ("comma at root", "1,2"),
    ("unterminated string", #"["abc"#),
    ("unterminated key", #"{"abc"#),
    ("control in string", "[\"a\u{01}b\"]"),
    ("control in key", "{\"a\u{01}b\":1}"),
    ("nul outside", "[\u{0}]"),
    ("bad escape", #"["a\xb"]"#),
    ("bad unicode escape", #"["\u12G4"]"#),
    ("lone high surrogate", #"["\ud83d"]"#),
    ("lone high surrogate then char", #"["\ud83dabc"]"#),
    ("lone low surrogate", #"["\ude00"]"#),
    ("high then non-low", #"["\ud83d\u0041"]"#),
    ("bad escape in key", #"{"a\xb":1}"#),
    ("non-ascii outside string", "[é]"),
    ("depth 64", String(repeating: "[", count: 64) + String(repeating: "]", count: 64)),
    ("depth 65", String(repeating: "[", count: 65) + String(repeating: "]", count: 65)),
    ("unterminated container", "[1,2"),
  ]

  @Test(arguments: Self.documents.map(\.0))
  func `Every document parses identically on both paths`(name: String) {
    let document = Self.documents.first { $0.0 == name }!.1
    Self.expectEquivalent(Array(document.utf8), name)
  }

  @Test
  func `Invalid UTF-8 is rejected at the same offset`() {
    let cases: [(String, [UInt8])] = [
      ("overlong", Array("[\"".utf8) + [0xC0, 0x80] + Array("\"]".utf8)),
      ("truncated", Array("[\"".utf8) + [0xE2, 0x82] + Array("\"]".utf8)),
      ("surrogate", Array("[\"".utf8) + [0xED, 0xA0, 0x80] + Array("\"]".utf8)),
      ("bare continuation", Array("[\"ab".utf8) + [0x80] + Array("cd\"]".utf8)),
      ("in key", Array("{\"a".utf8) + [0xFF] + Array("\":1}".utf8)),
      (
        "late in a long string",
        Array("[\"".utf8) + Array(repeating: UInt8(ascii: "a"), count: 500) + [0xC3]
          + Array("\"]".utf8)
      ),
    ]
    for (name, bytes) in cases {
      Self.expectEquivalent(bytes, name)
    }
  }

  @Test
  func `Resource documents parse identically on both paths`() throws {
    for name in ["64KB", "512KB", "DeepNested64"] {
      let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
      Self.expectEquivalent(Array(try Data(contentsOf: url)), name)
    }
  }

  // Where a sink rejection surfaces must not depend on the path either: the parser reads the
  // failure at the byte after the token, and the walk has to read it there too.
  @Test(arguments: ["object", "array", "key", "stringBegin", "stringEnd", "number", "boolean", "null", "endObject", "endArray"])
  func `Sink rejections surface at the same offset`(kind: String) {
    let documents = [
      #"{"a":[1,"s",true,null,{"b":2}],"c":"d"}"#,
      #"[  1 , "s" , true , null , {  "b" : 2 } ]"#,
      #"{"a":1,"b":"x\ny","c":[false]}"#,
    ]
    for document in documents {
      Self.expectEquivalent(Array(document.utf8), "\(kind) in \(document)", rejecting: [kind])
    }
  }
}
