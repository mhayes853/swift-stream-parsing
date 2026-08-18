import Foundation
import Testing

import StreamParsing
import StreamParsingCore

@StreamParseable
private struct StringFieldModel: Equatable {
  var title: String = ""
  var body: String = ""
}

// The accumulation type behind every parsed string field. Blocks are 512 bytes and seal exactly
// when they fill, so the sizes here are chosen to land content on both sides of a boundary and
// to straddle one with a multi-byte character.
@Suite
struct `Stream string tests` {
  private func accumulated(_ content: [UInt8], chunk: Int) -> StreamString {
    var value = StreamString()
    content.withUnsafeBufferPointer { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = min(chunk, buffer.count - offset)
        let slice = UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: count)
        value.streamAppend(utf8: Span(_unsafeElements: slice))
        offset += count
      }
    }
    return value
  }

  // MARK: - Accumulation

  @Test(arguments: [1, 7, 64, 512, 4096, Int.max])
  func `Chunking does not change the accumulated string`(chunk: Int) {
    let content = String(repeating: "chunk boundary content ", count: 200)
    let value = self.accumulated(Array(content.utf8), chunk: chunk)
    #expect(value.utf8Count == content.utf8.count)
    #expect(String(value) == content)
  }

  @Test
  func `A multi byte character straddling a block boundary decodes whole`() {
    // 511 ASCII bytes, then a three byte character: its bytes split 1/2 across the first seal.
    let content = String(repeating: "a", count: 511) + "€" + String(repeating: "b", count: 600)
    let value = self.accumulated(Array(content.utf8), chunk: 64)
    #expect(String(value) == content)
  }

  @Test
  func `Appending nothing allocates nothing and stays empty`() {
    let value = self.accumulated([], chunk: 1)
    #expect(value.isEmpty)
    #expect(value.utf8Count == 0)
    #expect(String(value) == "")
  }

  // MARK: - Value semantics

  @Test
  func `A copy taken mid accumulation does not see later appends`() {
    let head = String(repeating: "sealed ", count: 100)
    var value = self.accumulated(Array(head.utf8), chunk: 8)
    let snapshot = value
    let tailBytes = Array("appended after the copy".utf8)
    tailBytes.withUnsafeBufferPointer { buffer in
      value.streamAppend(utf8: Span(_unsafeElements: buffer))
    }
    #expect(String(snapshot) == head)
    #expect(String(value) == head + "appended after the copy")
  }

  // MARK: - Equality and hashing

  @Test
  func `Equality and hashing ignore how the bytes arrived`() {
    let content = String(repeating: "equal content across chunkings ", count: 60)
    let byByte = self.accumulated(Array(content.utf8), chunk: 1)
    let bulk = self.accumulated(Array(content.utf8), chunk: .max)
    #expect(byByte == bulk)
    #expect(byByte.hashValue == bulk.hashValue)
  }

  @Test
  func `Comparison against String works in every optional shape`() {
    let expected = "compared against a variable"
    let value = StreamString(expected)
    let optional = StreamString?.some(value)
    #expect(value == expected)
    #expect(expected == value)
    #expect(optional == expected)
    #expect(expected == optional)
    #expect(value != expected + "!")
    #expect(StreamString?.none != expected)
    #expect(value == expected[...])
  }

  @Test
  func `Equality is byte wise, not canonical`() {
    // NFC and NFD spellings of the same character are equal as `String` and different here,
    // because decoded JSON text compares as the scalars the document actually carried.
    let composed = StreamString("\u{E9}")
    let decomposed = StreamString("e\u{301}")
    #expect("\u{E9}" == String("e\u{301}"))
    #expect(composed != decomposed)
  }

  // MARK: - Reading

  @Test
  func `Byte offsets slice into decoded substrings`() {
    let head = String(repeating: "x", count: 700)
    let content = head + "the suffix"
    let value = self.accumulated(Array(content.utf8), chunk: 100)
    #expect(String(value.utf8[700...]) == "the suffix")
    #expect(String(value.utf8[0..<3]) == "xxx")
    // A range crossing a block boundary, decoded through the gathering path.
    #expect(String(value.utf8[510..<514]) == "xxxx")
    #expect(value.utf8[702] == UInt8(ascii: "e"))
  }

  @Test
  func `Prefix, suffix and containment match byte wise across block boundaries`() {
    // 500 bytes of padding puts the needle astride the first block seal at 512.
    let value = self.accumulated(
      Array((String(repeating: "p", count: 500) + "needle in a haystack").utf8), chunk: 64
    )
    #expect(value.hasPrefix("ppp"))
    #expect(value.hasPrefix(""))
    #expect(!value.hasPrefix("q"))
    #expect(value.hasSuffix("haystack"))
    #expect(value.hasSuffix(""))
    #expect(!value.hasSuffix("needle"))
    #expect(value.contains("needle in"))
    #expect(value.contains(""))
    #expect(!value.contains("needle out"))
    #expect(!StreamString().contains("x"))
    // Longer than the content is a plain miss, not a bounds trap.
    #expect(!StreamString("ab").hasPrefix("abc"))
    #expect(!StreamString("ab").hasSuffix("abc"))
    // Byte-wise, like `==`: an NFD spelling does not match an NFC prefix.
    #expect(!StreamString("e\u{301}tude").hasPrefix("\u{E9}"))
  }

  @Test
  func `Byte ranges from search feed decoding doors`() {
    // The first hit sits astride the 512 seal; the second is in the tail.
    let content = String(repeating: "p", count: 508) + "marker middle marker end"
    let value = self.accumulated(Array(content.utf8), chunk: 64)
    let first = value.range(of: "marker")
    #expect(first == 508..<514)
    #expect(String(value.utf8[first!]) == "marker")
    #expect(Substring(value.utf8[first!]) == "marker")
    let second = value.range(of: "marker", from: first!.upperBound)
    #expect(second == 522..<528)
    #expect(value.range(of: "marker", from: second!.upperBound) == nil)
    #expect(value.range(of: "absent") == nil)
    #expect(value.range(of: "end")?.upperBound == value.utf8Count)
    #expect(value.range(of: "") == 0..<0)
    #expect(value.range(of: "", from: 5) == 5..<5)
    #expect(value.range(of: "longer than the tail", from: value.utf8Count) == nil)
    // Byte-wise honesty: the search lands mid-cluster inside a decomposed character.
    let decomposed = StreamString("e\u{301}!")
    #expect(decomposed.range(of: "e") == 0..<1)
    #expect(decomposed.range(of: "!") == 3..<4)
  }

  @Test
  func `Substrings bridge into the StringProtocol world`() {
    let content = String(repeating: "bridge ", count: 100)
    let value = self.accumulated(Array(content.utf8), chunk: 32)
    #expect(Substring(value) == content[...])
    #expect(Substring(value.utf8[0..<6]) == "bridge")
    func generic(_ text: some StringProtocol) -> Int { text.count }
    #expect(generic(Substring(value)) == content.count)
  }

  @Test
  func `Unicode scalars agree with String in both directions`() {
    // Multi-byte scalars pushed astride the first block seal at 512.
    let content = String(repeating: "a", count: 509) + "€é✓𝄞 plain tail"
    let value = self.accumulated(Array(content.utf8), chunk: 64)
    let view = value.unicodeScalars
    #expect(Array(view) == Array(content.unicodeScalars))
    var backward = [Unicode.Scalar]()
    var index = view.endIndex
    while index > view.startIndex {
      index = view.index(before: index)
      backward.append(view[index])
    }
    #expect(backward.reversed() == Array(content.unicodeScalars))
  }

  @Test
  func `Ill-formed bytes decode as one replacement scalar per byte`() {
    let value = self.accumulated([0x61, 0xFF, 0x80, 0x62], chunk: .max)
    #expect(Array(value.unicodeScalars) == ["a", "\u{FFFD}", "\u{FFFD}", "b"])
    #expect(value.unicodeScalars.index(before: 3) == 2)
  }

  @Test
  func `Character Sequence Agrees With String, Clusters Included`() {
    // The family emoji is 25 bytes and the flag is a regional-indicator pair. Padding puts both
    // across block boundaries while the sequence still yields the same Character values as
    // String iteration.
    let content = String(repeating: "x", count: 505) + "e\u{301}👨‍👩‍👧‍👦🇺🇸 end"
    let value = self.accumulated(Array(content.utf8), chunk: 32)
    #expect(Array(value.characters) == Array(content))
  }

  @Test
  func `Appending composes accumulations without materializing`() {
    var value = self.accumulated(Array(String(repeating: "left ", count: 200).utf8), chunk: 64)
    let other = self.accumulated(Array("right".utf8), chunk: 1)
    value.append(other)
    value += " and more"
    value.append(Character("!"))
    #expect(String(value) == String(repeating: "left ", count: 200) + "right and more!")
    let joined = StreamString("a") + StreamString("b")
    #expect(joined == "ab")
    print("printed", terminator: "", to: &value)
    #expect(value.hasSuffix("!printed"))
  }

  @Test
  func `Streaming out preserves characters across block cuts`() {
    // A three byte scalar sits astride the 512 seal, so a per-block write would tear it.
    let content = String(repeating: "y", count: 511) + "€ tail"
    let value = self.accumulated(Array(content.utf8), chunk: 128)
    var target = ""
    value.write(to: &target)
    #expect(target == content)
  }

  @Test
  func `Interpolation builds without an intermediate whole String`() {
    let piece = StreamString("piece")
    let value: StreamString = "a \(piece) of \(42) and \("text"[...])"
    #expect(value == "a piece of 42 and text")
  }

  @Test
  func `Ordering is byte wise scalar order`() {
    #expect(StreamString("abc") < StreamString("abd"))
    #expect(StreamString("ab") < StreamString("abc"))
    #expect(!(StreamString("abc") < StreamString("abc")))
    // Scalar-value order: U+00E9 sorts after ASCII, and byte-wise agrees.
    #expect(StreamString("z") < StreamString("\u{E9}"))
    // A difference in the second 512-byte window.
    let sharedHead = String(repeating: "s", count: 600)
    let low = self.accumulated(Array((sharedHead + "a").utf8), chunk: 64)
    let high = self.accumulated(Array((sharedHead + "b").utf8), chunk: .max)
    #expect(low < high)
    #expect(!(high < low))
    #expect([StreamString("b"), "a", "c"].sorted() == ["a", "b", "c"])
  }

  @Test
  func `Debug description quotes like String`() {
    #expect(StreamString("say \"hi\"\n").debugDescription == "say \"hi\"\n".debugDescription)
  }

  @Test
  func `Invalid UTF-8 decodes repaired rather than trapping`() {
    // Unchecked-mode parses can accumulate invalid bytes, so materialization has to repair.
    let value = self.accumulated([0x61, 0xFF, 0x62], chunk: .max)
    #expect(String(value) == "a\u{FFFD}b")
  }

  @Test
  func `Literal, description and bridging agree`() {
    let value: StreamString = "spelled as a literal"
    #expect(value.description == "spelled as a literal")
    #expect(String(value) == "spelled as a literal")
    #expect("spelled as a literal".streamPartialValue == value)
  }

  @Test
  func `Codable round trips through the string it stands in for`() throws {
    let value = StreamString(String(repeating: "codable content ", count: 80))
    let encoded = try JSONEncoder().encode(value)
    let expected = try JSONEncoder().encode(String(value))
    #expect(encoded == expected)
    let decoded = try JSONDecoder().decode(StreamString.self, from: encoded)
    #expect(decoded == value)
  }

  // MARK: - Parsing

  @Test(arguments: [1, 16, Int.max])
  func `A parsed string field accumulates into a StreamString`(chunk: Int) throws {
    var value = StringFieldModel.Partial()
    let body = String(repeating: "escaped\\nline ", count: 120)
    try parsePartial(
      #"{"title":"The Title","body":"\#(body)"}"#, into: &value, chunk: chunk
    )
    #expect(value.title == "The Title")
    #expect(value.body == body.replacingOccurrences(of: "\\n", with: "\n"))
  }

  @Test
  func `A snapshot kept mid string stays fixed while parsing continues`() throws {
    let json = #"{"body":"first half|second half"}"#
    var stream = PartialsStream(initialValue: StringFieldModel.Partial(), from: .json())
    let bytes = Array(json.utf8)
    let split = Array(json.utf8).firstIndex(of: UInt8(ascii: "|"))!
    try stream.next(bytes[..<split])
    let snapshot = stream.current
    try stream.next(bytes[split...])
    let final = try stream.finish()
    #expect(snapshot.body == "first half")
    #expect(final.body == "first half|second half")
  }
}

@Test(arguments: [0, 7, 8, 15, 16, 17, 511, 512, 513, 8_191])
func `Ordering Uses The First Difference Across SIMD And Block Boundaries`(offset: Int) {
  var lowBytes = Array(repeating: UInt8(ascii: "m"), count: offset &+ 2)
  var highBytes = lowBytes
  lowBytes[offset] = UInt8(ascii: "a")
  highBytes[offset] = UInt8(ascii: "b")
  lowBytes[offset &+ 1] = UInt8(ascii: "z")
  highBytes[offset &+ 1] = UInt8(ascii: "a")
  let low = StreamString(String(decoding: lowBytes, as: UTF8.self))
  let high = StreamString(String(decoding: highBytes, as: UTF8.self))
  #expect(low < high)
  #expect(!(high < low))
}
