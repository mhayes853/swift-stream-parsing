import CustomDump
import Testing

import StreamParsingCore

// The structural run reads a key in place and then walks to the value through the colon. Any
// shortcut across that stretch has to hold for every spelling of it, not just the one every
// pretty printer emits — `"key": value` is universal in the corpus but not in the grammar, and a
// peel that assumes one space is a correctness bug the corpus cannot show.
//
// Every case is asserted as a whole tree rather than as "did not throw", because the failure a
// fusion produces is a value attached to the wrong key, not an exception. Every case runs at every
// chunk boundary and again one byte at a time, since the peel is exactly what a chunk cut
// disables.
@Suite
struct `Key colon fusion tests` {
  private static func tree(_ bytes: [UInt8], splitAt: Int) throws -> TreeSink.Node? {
    var parser = JSONParser()
    var sink = TreeSink()
    try bytes.withUnsafeBufferPointer { buffer in
      let first = UnsafeBufferPointer(start: buffer.baseAddress, count: splitAt)
      let second = UnsafeBufferPointer(
        start: buffer.baseAddress! + splitAt, count: buffer.count &- splitAt
      )
      if !first.isEmpty { try parser.parse(first, into: &sink) }
      if !second.isEmpty { try parser.parse(second, into: &sink) }
    }
    try parser.finish(into: &sink)
    return sink.value
  }

  private static func treeBytewise(_ bytes: [UInt8]) throws -> TreeSink.Node? {
    var parser = JSONParser()
    var sink = TreeSink()
    for byte in bytes {
      try parser.parse(byte: byte, into: &sink)
    }
    try parser.finish(into: &sink)
    return sink.value
  }

  private static func expect(
    _ json: String,
    _ expected: TreeSink.Node,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) throws {
    let bytes = Array(json.utf8)
    for split in 0...bytes.count {
      expectNoDifference(
        try Self.tree(bytes, splitAt: split), expected, "\(json) split at \(split)",
        fileID: fileID, filePath: filePath, line: line, column: column
      )
    }
    expectNoDifference(
      try Self.treeBytewise(bytes), expected, "\(json) byte by byte",
      fileID: fileID, filePath: filePath, line: line, column: column
    )
  }

  private static func expectRejected(
    _ json: String, _ sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let bytes = Array(json.utf8)
    for split in 0...bytes.count {
      #expect(
        throws: (any Error).self, "\(json) split at \(split)", sourceLocation: sourceLocation
      ) {
        try Self.tree(bytes, splitAt: split)
      }
    }
    #expect(throws: (any Error).self, "\(json) byte by byte", sourceLocation: sourceLocation) {
      try Self.treeBytewise(bytes)
    }
  }

  private static func member(_ key: String, _ value: TreeSink.Node) -> TreeSink.Node {
    .object([(key, value)])
  }

  // MARK: Whitespace around the colon

  @Test
  func `No whitespace at all`() throws {
    try Self.expect(#"{"a":"b"}"#, Self.member("a", .string("b")))
  }

  @Test
  func `The one space every printer emits`() throws {
    try Self.expect(#"{"a": "b"}"#, Self.member("a", .string("b")))
  }

  // Not in any corpus document, and legal. The peel reaches the colon through the whitespace
  // scanner rather than a bare compare precisely so this case stays correct *and* fast.
  @Test
  func `Whitespace before the colon`() throws {
    try Self.expect(#"{"a" : "b"}"#, Self.member("a", .string("b")))
  }

  @Test
  func `Multi byte whitespace on both sides of the colon`() throws {
    try Self.expect("{\"a\" \t\r\n : \t\r\n \"b\"}", Self.member("a", .string("b")))
  }

  // Longer than a SIMD16 window, so the whitespace between key and colon spans a vector and the
  // scan's wide tier runs where the fast path would have answered.
  @Test
  func `Whitespace longer than a vector`() throws {
    let gap = String(repeating: " ", count: 40)
    try Self.expect("{\"a\"\(gap):\(gap)\"b\"}", Self.member("a", .string("b")))
  }

  // MARK: What follows the colon

  @Test
  func `Every value shape after a colon`() throws {
    try Self.expect(#"{"a": "b"}"#, Self.member("a", .string("b")))
    try Self.expect(#"{"a": 42}"#, Self.member("a", .number("42")))
    try Self.expect(#"{"a": -1.5e3}"#, Self.member("a", .number("-1.5e3")))
    try Self.expect(#"{"a": true}"#, Self.member("a", .boolean(true)))
    try Self.expect(#"{"a": false}"#, Self.member("a", .boolean(false)))
    try Self.expect(#"{"a": null}"#, Self.member("a", .null))
    try Self.expect(#"{"a": {}}"#, Self.member("a", .object([])))
    try Self.expect(#"{"a": []}"#, Self.member("a", .array([])))
    try Self.expect(#"{"a": {"b": 1}}"#, Self.member("a", Self.member("b", .number("1"))))
    try Self.expect(#"{"a": [1, "x"]}"#, Self.member("a", .array([.number("1"), .string("x")])))
  }

  @Test
  func `An empty value string`() throws {
    try Self.expect(#"{"a": ""}"#, Self.member("a", .string("")))
  }

  // MARK: Keys the in place read cannot take

  // An escape in the key sends it through `consumeKeyRun`'s buffered path, which never reaches
  // the peel — so this is the case that proves the peel is not the only way to the colon.
  @Test
  func `An escaped key still reaches its value`() throws {
    try Self.expect("{\"a\\\"b\": \"c\"}", Self.member("a\"b", .string("c")))
    try Self.expect("{\"a\\nb\": \"c\"}", Self.member("a\nb", .string("c")))
  }

  @Test
  func `An empty key`() throws {
    try Self.expect(#"{"": "b"}"#, Self.member("", .string("b")))
  }

  // Longer than one SIMD16 window and longer than the x86 narrow tier's 32 byte escalation
  // bound, so the key's own scan ends in the wide tier and the colon that follows it is not in
  // the vector the scan last loaded.
  @Test
  func `A key longer than the scanner's tiers`() throws {
    let key = String(repeating: "k", count: 70)
    try Self.expect("{\"\(key)\": \"b\"}", Self.member(key, .string("b")))
  }

  @Test
  func `A non ASCII key`() throws {
    try Self.expect(#"{"café": "b"}"#, Self.member("café", .string("b")))
  }

  // MARK: Several members, so the fusion runs back to back

  @Test
  func `Consecutive members`() throws {
    try Self.expect(
      #"{"a": 1, "b": "two", "c": null}"#,
      .object([("a", .number("1")), ("b", .string("two")), ("c", .null)])
    )
  }

  @Test
  func `Nested objects with mixed spacing`() throws {
    try Self.expect(
      "{\"a\":{\"b\" : {\"c\":\t\"d\"}},\"e\":1}",
      .object([
        ("a", Self.member("b", Self.member("c", .string("d")))),
        ("e", .number("1"))
      ])
    )
  }

  // MARK: What must still be rejected

  @Test
  func `A key with no colon`() {
    Self.expectRejected(#"{"a"}"#)
    Self.expectRejected(#"{"a" "b"}"#)
    Self.expectRejected(#"{"a" x "b"}"#)
    Self.expectRejected(#"{"a", "b"}"#)
  }

  @Test
  func `A colon with no value`() {
    Self.expectRejected(#"{"a":}"#)
    Self.expectRejected(#"{"a": }"#)
    Self.expectRejected(#"{"a": ,}"#)
  }

  @Test
  func `Two colons`() {
    Self.expectRejected(#"{"a"::"b"}"#)
    Self.expectRejected(#"{"a": : "b"}"#)
  }

  // A colon is only legal after a key. The peel sets `.value` directly, so a stray colon must
  // still be caught by the state it lands in rather than by the arm that consumed it.
  @Test
  func `A colon where a value belongs`() {
    Self.expectRejected(#"[:]"#)
    Self.expectRejected(#"{"a": ":"# + "}")
    Self.expectRejected(#"{"a": 1:}"#)
  }
}
