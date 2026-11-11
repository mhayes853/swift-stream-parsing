import CustomDump
import Foundation
import StreamParsing
import StreamParsingCore
import Testing

// MARK: - 6. Grammar and errors
//
// The parser accepts exactly RFC 8259 JSON. Being lenient is not a kindness here: a structured
// output consumer that accepts a malformed document acts on data that was never valid.

@Suite
struct `Grammar and errors` {
  // GR-1
  @Test(arguments: [
    "0", "-0", "1.5e-3", "1E+2", #""""#, #""a""#, "true", "false", "null",
    "[]", "{}", "[[]]", #"{"":{}}"#, #"[1,"a",true,null,{},[]]"#,
    " \t\r\n[ 1 , 2 ]\n ", #"{ "a" : [ { "b" : null } ] }"#,
    "[" + String(repeating: "1,", count: 10_000) + "1]",
  ])
  func `Every valid JSON value shape is accepted, at the root and byte by byte`(json: String) throws {
    let bytes = Array(json.utf8)
    var sink = TreeSink()
    try parseRaw(bytes, into: &sink)
    expectNoDifference(sink.root, try JSONValue.foundation(bytes))
    #expect(rawParsingError(bytes, chunking: .fixed(1)) == nil)
  }

  // Duplicate keys are legal JSON (RFC 8259 leaves their meaning to the receiver), so the parser
  // delivers both members and leaves the policy to the sink.
  @Test
  func `Duplicate keys are accepted and both members are delivered`() throws {
    var sink = KeyCountingSink()
    try parseRaw(Array(#"{"a":1,"a":2}"#.utf8), into: &sink)
    #expect(sink.keys == ["a", "a"])
  }

  // GR-2
  @Test(arguments: [
    // Structure
    "", " ", "[", "]", "{", "}", "[1,]", "[,1]", "[1,,2]", #"{"a":1,}"#, #"{,"a":1}"#, "[1 2]",
    #"{"a" 1}"#, #"{"a":}"#, #"{"a"}"#, #"{1:1}"#, "{a:1}", "[1}", #"{"a":1]"#, "[1]]",
    // Content after the root value
    "1 2", "[] []", "{}x", "null,", #""a" "b""#,
    // Numbers
    "01", "-", "+1", ".5", "1.", "1.e1", "1e", "1e+", "0x10", "NaN", "Infinity", "-Infinity", "1_000",
    // Literals
    "tru", "nul", "True", "NULL", "falsey",
    // Strings
    "'a'", #""a"#, #""\x""#, #""\u12""#, #""\u12G4""#, #""\"#,
    // Things other formats allow
    "// c\n1", "/* c */1", "[1] // c",
  ])
  func `Malformed documents are rejected, in bulk and byte by byte`(json: String) {
    let bytes = Array(json.utf8)
    #expect(rawParsingError(bytes) != nil, "\(json.debugDescription) was accepted")
    #expect(rawParsingError(bytes, chunking: .fixed(1)) != nil, "\(json.debugDescription) byte-fed")
  }

  // GR-3
  // A stream that ends early is the normal failure of a network or an LLM: every proper prefix of
  // a real document is accepted by `next` (it could still be completed) and refused by `finish`.
  @Test
  func `Every truncation of a real document is accepted mid-stream and refused at finish`() throws {
    let bytes = try firstGitHubEvent()
    for end in 1..<bytes.count {
      var stream = PartialsStream<CorpusGitHubEvent>(from: .json())
      do {
        try stream.next(bytes[..<end])
      } catch {
        Issue.record("prefix of \(end) bytes rejected mid-stream: \(error)")
        return
      }
      do {
        _ = try stream.finishPartial()
        Issue.record("prefix of \(end) bytes finished successfully")
        return
      } catch let error as JSONParsingError {
        // The reason varies with where the cut fell (`.unterminatedString` inside a string,
        // `.invalidLiteral` inside `tru`, `.unexpectedToken` after a comma or colon), but it is
        // always a grammar error within the bytes actually given.
        #expect(error.byteOffset <= end, "prefix \(end): \(error)")
        #expect(
          [.unterminatedContainer, .unterminatedString, .invalidLiteral, .invalidNumber,
            .unexpectedToken].contains(error.reason),
          "prefix \(end): \(error.reason)"
        )
      }
    }
  }

  // GR-4
  // Nesting is capped at 64 levels in every container kind, whatever the chunking -- and an
  // attacker's 100 000 open brackets fail cleanly instead of exhausting the stack.
  @Test(arguments: [Chunking.whole, .fixed(1), .fixed(3)])
  func `Nesting is capped at 64 levels and deep input fails cleanly`(chunking: Chunking) {
    func arrays(_ depth: Int) -> [UInt8] {
      Array((String(repeating: "[", count: depth) + String(repeating: "]", count: depth)).utf8)
    }
    func objects(_ depth: Int) -> [UInt8] {
      Array((String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)).utf8)
    }
    #expect(rawParsingError(arrays(64), chunking: chunking) == nil)
    #expect(rawParsingError(objects(64), chunking: chunking) == nil)
    #expect(rawParsingError(arrays(65), chunking: chunking)?.reason == .depthExceeded)
    #expect(rawParsingError(objects(65), chunking: chunking)?.reason == .depthExceeded)
    let hostile = Array(repeating: UInt8(ascii: "["), count: 100_000)
    #expect(rawParsingError(hostile, chunking: chunking)?.reason == .depthExceeded)
    #expect(rawParsingError(hostile, chunking: chunking)?.byteOffset == 64)
  }

  // GR-5
  // An error's byte offset is absolute in the document -- counted across every chunk fed so far --
  // and identifies the offending byte (for a number, the delimiter that completed the bad token),
  // so a consumer can point at it.
  @Test(arguments: [
    (#"{"a":[1,2,x]}"#, 10, JSONParsingError.Reason.unexpectedToken),
    (#"{"a":tru}"#, 8, .invalidLiteral),  // the byte that cannot continue the literal
    (#"{"a":"\q"}"#, 7, .invalidEscape),
    (#"[1,2]   ,"#, 8, .trailingContent),
    (#"[01]"#, 3, .invalidNumber),  // a number is judged whole, at the delimiter that ends it
  ])
  func `An error reports the absolute offset of the offending byte under every chunking`(
    json: String, offset: Int, reason: JSONParsingError.Reason
  ) {
    let bytes = Array(json.utf8)
    for chunking in [Chunking.whole, .fixed(1), .fixed(2), .fixed(4)] {
      let error = rawParsingError(bytes, chunking: chunking)
      #expect(error?.reason == reason, "\(json) at \(chunking)")
      #expect(error?.byteOffset == offset, "\(json) at \(chunking)")
    }
  }
}

/// Records the keys it is given, in order.
struct KeyCountingSink: StreamParseSink {
  var keys = [String]()
  var streamFailure: StreamSinkFailure?

  mutating func beginObject() -> StreamContainerDisposition { .stream }
  mutating func endObject() {}
  mutating func beginArray() -> StreamContainerDisposition { .stream }
  mutating func endArray() {}
  mutating func key(_ bytes: Span<UInt8>) {
    self.keys.append(bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) })
  }
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {}
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}
