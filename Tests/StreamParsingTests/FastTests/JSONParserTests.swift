import Foundation
import Testing

import StreamParsingCore

// Materializes events into a tree so results can be compared against JSONSerialization.
struct TreeSink: StreamParseSink {
  enum Node: Equatable {
    case object([(String, Node)])
    case array([Node])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null

    static func == (lhs: Node, rhs: Node) -> Bool {
      switch (lhs, rhs) {
      case (.object(let l), .object(let r)):
        l.count == r.count && zip(l, r).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
      case (.array(let l), .array(let r)): l == r
      case (.string(let l), .string(let r)): l == r
      case (.number(let l), .number(let r)): l == r
      case (.boolean(let l), .boolean(let r)): l == r
      case (.null, .null): true
      default: false
      }
    }
  }

  private enum Frame {
    case object([(String, Node)], pendingKey: String?)
    case array([Node])
  }

  private var frames = [Frame]()
  private var root: Node?
  private var currentString = ""
  private var currentKey = ""
  private var buildingKey = false

  var streamFailure: StreamSinkFailure?

  var value: Node? { self.root }
  private(set) var numbers = [NumberInfo]()

  mutating func beginObject() { self.frames.append(.object([], pendingKey: nil)) }
  mutating func beginArray() { self.frames.append(.array([])) }

  mutating func endObject() {
    guard case .object(let members, _)? = self.frames.popLast() else { return }
    self.deliver(.object(members))
  }

  mutating func endArray() {
    guard case .array(let elements)? = self.frames.popLast() else { return }
    self.deliver(.array(elements))
  }

  mutating func keyBegin() {
    self.buildingKey = true
    self.currentKey = ""
  }

  mutating func keyChunk(_ bytes: Span<UInt8>) {
    bytes.withUnsafeBufferPointer { self.currentKey += String(decoding: $0, as: UTF8.self) }
  }

  mutating func keyEnd() {
    self.buildingKey = false
    guard case .object(let members, _)? = self.frames.last else { return }
    self.frames[self.frames.count - 1] = .object(members, pendingKey: self.currentKey)
  }

  mutating func stringBegin() { self.currentString = "" }

  mutating func stringChunk(_ bytes: Span<UInt8>) {
    bytes.withUnsafeBufferPointer { self.currentString += String(decoding: $0, as: UTF8.self) }
  }

  mutating func stringEnd() { self.deliver(.string(self.currentString)) }

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.numbers.append(info)
    var text = ""
    bytes.withUnsafeBufferPointer { text = String(decoding: $0, as: UTF8.self) }
    self.deliver(.number(text))
  }

  mutating func boolean(_ value: Bool) { self.deliver(.boolean(value)) }
  mutating func null() { self.deliver(.null) }

  private mutating func deliver(_ node: Node) {
    guard let frame = self.frames.last else {
      self.root = node
      return
    }
    switch frame {
    case .object(var members, let pendingKey):
      members.append((pendingKey ?? "", node))
      self.frames[self.frames.count - 1] = .object(members, pendingKey: nil)
    case .array(var elements):
      elements.append(node)
      self.frames[self.frames.count - 1] = .array(elements)
    }
  }
}

private func parse(_ json: String, chunk: Int = .max) throws -> TreeSink {
  var parser = JSONParser()
  var sink = TreeSink()
  let bytes = Array(json.utf8)
  try bytes.withUnsafeBufferPointer { buffer in
    var i = 0
    while i < buffer.count {
      let count = min(chunk, buffer.count - i)
      let slice = UnsafeBufferPointer(start: buffer.baseAddress! + i, count: count)
      try parser.parse(slice, into: &sink)
      i += count
    }
  }
  try parser.finish(into: &sink)
  return sink
}

private func describe(_ any: Any) -> String {
  if let dictionary = any as? [String: Any] {
    return "{" + dictionary.keys.sorted().map { "\($0):\(describe(dictionary[$0]!))" }
      .joined(separator: ",") + "}"
  }
  if let array = any as? [Any] {
    return "[" + array.map(describe).joined(separator: ",") + "]"
  }
  if let number = any as? NSNumber {
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
    return number.stringValue
  }
  if let string = any as? String { return "\"\(string)\"" }
  return "null"
}

private func describe(_ node: TreeSink.Node) -> String {
  switch node {
  case .object(let members):
    return "{" + members.sorted { $0.0 < $1.0 }.map { "\($0.0):\(describe($0.1))" }
      .joined(separator: ",") + "}"
  case .array(let elements):
    return "[" + elements.map(describe).joined(separator: ",") + "]"
  case .string(let text): return "\"\(text)\""
  case .number(let text):
    // Routing integers through Double would lose precision past 2^53, which is a property of
    // this comparison rather than of the parser.
    if !text.contains("."), !text.lowercased().contains("e") { return text }
    return NSNumber(value: Double(text) ?? .nan).stringValue
  case .boolean(let value): return value ? "true" : "false"
  case .null: return "null"
  }
}

@Suite
struct `JSON parser tests` {
  static let valid = [
    #"{"id":4,"name":"Blob","isActive":true,"score":98.25,"missing":null}"#,
    #"{"users":[{"id":1,"name":"A"},{"id":2,"name":"B"}],"total":2}"#,
    #"[]"#,
    #"{}"#,
    #"[1,2,3]"#,
    #"[[1,2],[3,4]]"#,
    #"{"nested":{"deep":{"deeper":{"value":1}}}}"#,
    #"  {  "a" : 1 , "b" : [ true , false ]  }  "#,
    #"{"escaped":"a\nb\tc\"d\\e\/f"}"#,
    #"{"unicode":"é€"}"#,
    #"{"surrogate":"😀"}"#,
    #"{"utf8":"Aé€😀"}"#,
    #"{"numbers":[0,-1,1.5,-98.25,1e3,1.5e-8,1E+2,123456789012345678]}"#,
    #""bare string""#,
    #"42"#,
    #"true"#,
    #"null"#,
  ]

  @Test(arguments: valid)
  func `Parses the same structure as JSONSerialization`(json: String) throws {
    let sink = try parse(json)
    let node = try #require(sink.value)
    let reference = try JSONSerialization.jsonObject(
      with: Data(json.utf8), options: [.fragmentsAllowed]
    )
    #expect(describe(node) == describe(reference), "\(json)")
  }

  @Test(arguments: valid)
  func `Produces the same structure at every chunk size`(json: String) throws {
    let whole = try #require(parse(json).value)
    for chunk in [1, 2, 3, 5, 8] {
      let chunked = try #require(parse(json, chunk: chunk).value)
      #expect(chunked == whole, "\(json) at chunk \(chunk)")
    }
  }

  @Test(arguments: [
    #"{"# ,
    #"{"a""#,
    #"{"a":}"#,
    #"{"a" 1}"#,
    #"[1,]"#,
    #"{"a":1,}"#,
    #"[,1]"#,
    #"{,}"#,
    #"[1 2]"#,
    #"tru"#,
    #"trux"#,
    #""unterminated"#,
    #"{"a":1}}"#,
    #"[1]]"#,
  ])
  func `Rejects malformed input`(json: String) {
    #expect(throws: JSONParsingError.self) { try parse(json) }
  }

  // A number is reported exactly once, whole, at its token's end. A numeric prefix is not a
  // value prefix — 1234 passes through 1, 12 and 123 on the way — so nothing provisional is
  // reported, and a consumer never sees a value the document does not contain.
  @Test
  func `Reports a number once, whole`() throws {
    let sink = try parse("[1234]")
    #expect(sink.numbers.map(\.magnitude) == [1234])

    let exponent = try parse("[-1.5e2]")
    #expect(exponent.numbers.map(\.magnitude) == [15])
    #expect(exponent.numbers.map(\.exponent) == [1])
  }

  // A token split across chunks reports the same single value, and its span stays contiguous
  // across the boundary so a consumer that re-scans the bytes sees the whole token.
  @Test
  func `Reports the same single value across a chunk boundary`() throws {
    for chunk in [1, 2, 3, 5] {
      let sink = try parse("[-1.5e2]", chunk: chunk)
      #expect(sink.numbers.map(\.magnitude) == [15])
      #expect(sink.numbers.map(\.exponent) == [1])
    }
  }

  // The per-byte rules accepted a doubled exponent sign, because each sign only checked that no
  // exponent digit had arrived yet. The structured walk has one place for a sign, so these are
  // rejected by shape rather than by a tracked flag.
  @Test(arguments: ["[1e--2]", "[1e++2]", "[1e+-2]", "[1e-+2]"])
  func `Rejects doubled exponent signs`(json: String) {
    #expect(throws: JSONParsingError.self) { try parse(json) }
  }

  @Test
  func `Accumulates number info during the scan`() throws {
    let sink = try parse(#"[42,-7,1.5,1e3,98.25]"#)
    let infos = sink.numbers
    try #require(infos.count == 5)

    #expect(infos[0].magnitude == 42)
    #expect(infos[0].exponent == 0)
    #expect(!infos[0].flags.contains(.negative))

    #expect(infos[1].magnitude == 7)
    #expect(infos[1].flags.contains(.negative))

    #expect(infos[2].magnitude == 15)
    #expect(infos[2].exponent == -1)
    #expect(infos[2].flags.contains(.fraction))

    #expect(infos[3].magnitude == 1)
    #expect(infos[3].exponent == 3)
    #expect(infos[3].flags.contains(.exponent))

    #expect(infos[4].magnitude == 9825)
    #expect(infos[4].exponent == -2)
  }

  @Test
  func `Flags magnitudes beyond nineteen digits as overflowed`() throws {
    let sink = try parse(#"[99999999999999999999999]"#)
    let info = try #require(sink.numbers.first)
    #expect(info.flags.contains(.overflowed))
  }

  @Test
  func `Rejects nesting beyond the container stack`() {
    let json = String(repeating: "[", count: 70) + String(repeating: "]", count: 70)
    #expect(throws: JSONParsingError.self) { try parse(json) }
  }
}
