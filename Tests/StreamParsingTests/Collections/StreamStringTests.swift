import Foundation
import CustomDump
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

  @Test
  func `A multi byte character straddling a block boundary decodes whole`() {
    // 511 ASCII bytes, then a three byte character: its bytes split 1/2 across the first seal.
    let content = String(repeating: "a", count: 511) + "€" + String(repeating: "b", count: 600)
    let value = self.accumulated(Array(content.utf8), chunk: 64)
    expectNoDifference(String(value), content)
  }

  @Test
  func `Appending nothing allocates nothing and stays empty`() {
    let value = self.accumulated([], chunk: 1)
    expectNoDifference(value.isEmpty, true)
    expectNoDifference(value.utf8Count, 0)
    expectNoDifference(String(value), "")
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
    expectNoDifference(String(snapshot), head)
    expectNoDifference(String(value), head + "appended after the copy")
  }

  // The tail is replaced the moment a block seals, so a snapshot taken exactly there holds an empty
  // tail, and one taken just before holds the block the next append seals.
  @Test(arguments: [511, 512, 513])
  func `A copy taken at a seal does not see appends that seal blocks`(count: Int) {
    let head = Array(repeating: UInt8(ascii: "h"), count: count)
    var value = self.accumulated(head, chunk: 97)
    let snapshot = value
    let more = Array(repeating: UInt8(ascii: "m"), count: 2_000)
    more.withUnsafeBufferPointer { buffer in
      value.streamAppend(utf8: Span(_unsafeElements: buffer))
    }
    expectNoDifference(Array(snapshot.utf8), head)
    expectNoDifference(Array(value.utf8), head + more)
  }

  @Test(arguments: [40, 700, 9_000])
  func `Appending a value to itself doubles it`(count: Int) {
    let content = (0..<count).map { UInt8(97 + $0 % 26) }
    var value = self.accumulated(content, chunk: 333)
    let snapshot = value
    value.append(value)
    expectNoDifference(Array(value.utf8), content + content)
    expectNoDifference(Array(snapshot.utf8), content)
  }

  @Test
  func `Reserving on a shared value leaves the copy untouched`() {
    let content = Array(repeating: UInt8(ascii: "r"), count: 600)
    var value = self.accumulated(content, chunk: 64)
    let snapshot = value
    value.streamReserve(utf8ByteCount: 20_000)
    value.append("tail")
    expectNoDifference(Array(snapshot.utf8), content)
    expectNoDifference(String(value), String(decoding: content, as: UTF8.self) + "tail")
  }

  // MARK: - Equality and hashing

  @Test
  func `Equality and hashing ignore how the bytes arrived`() {
    let content = String(repeating: "equal content across chunkings ", count: 60)
    let byByte = self.accumulated(Array(content.utf8), chunk: 1)
    let bulk = self.accumulated(Array(content.utf8), chunk: .max)
    expectNoDifference(byByte, bulk)
    expectNoDifference(byByte.hashValue, bulk.hashValue)
  }

  @Test
  func `Comparison against String works in every optional shape`() {
    let expected = "compared against a variable"
    let value = StreamString(expected)
    let optional = StreamString?.some(value)
    expectNoDifference(value, StreamString(expected))
    expectNoDifference(StreamString(expected), value)
    expectNoDifference(optional, StreamString?.some(value))
    expectNoDifference(StreamString?.some(value), optional)
    expectNoDifference(value != expected + "!", true)
    expectNoDifference(StreamString?.none != expected, true)
    expectNoDifference(value, StreamString(expected[...]))
  }

  @Test
  func `Equality is canonical, as for String`() {
    let composed = StreamString("\u{E9}")
    let decomposed = StreamString("e\u{301}")
    expectNoDifference(composed == decomposed, true)
    expectNoDifference(composed.hashValue, decomposed.hashValue)
    expectNoDifference(composed == "e\u{301}", true)
    expectNoDifference("e\u{301}" == composed, true)
    // The Kelvin sign normalizes to an ASCII "K": an ASCII value equals a non-ASCII one, and the
    // two hashing paths have to agree.
    expectNoDifference(StreamString("\u{212A}") == StreamString("K"), true)
    expectNoDifference(StreamString("\u{212A}").hashValue, StreamString("K").hashValue)
    // Different lengths, differing only in ASCII past a shared non-ASCII prefix.
    expectNoDifference(StreamString("\u{E9}a") == StreamString("\u{E9}ab"), false)
  }

  @Test
  func `A value is unequal to its snapshot from before an append`() {
    var value = self.accumulated(Array(String(repeating: "grow ", count: 120).utf8), chunk: 64)
    for piece in ["ing", " and", " e\u{301}", "\u{E9}", "s", "s", ""] {
      let snapshot = value
      value.append(piece)
      // The last bytes settle most of these; a repeated or non-ASCII last byte reads further.
      let expected = String(value) == String(snapshot)
      #expect((value == snapshot) == expected, "\(piece.debugDescription)")
    }
  }

  @Test
  func `Comparison, ordering and hashing agree with String`() {
    // Long enough that some differences fall past the first 512-byte window and the inline limit.
    let padding = String(repeating: "p", count: 600)
    let texts = [
      "", "a", "ab", "abc", "abd", "K", "\u{212A}", "\u{E9}", "e\u{301}", "e", "ef", "z",
      "\u{C5}", "A\u{30A}", "\u{212B}", "q\u{323}\u{307}", "q\u{307}\u{323}", "\u{1E0B}\u{323}",
      "\u{1E0D}\u{307}", "😀", "가", "\u{1100}\u{1161}", ";", "\u{37E}",
    ]
    let corpus = texts + texts.map { padding + $0 } + texts.map { $0 + padding }
    for left in corpus {
      for right in corpus {
        let streamLeft = StreamString(left)
        let streamRight = StreamString(right)
        let pair = "\(left.debugDescription), \(right.debugDescription)"
        #expect((streamLeft == streamRight) == (left == right), "== \(pair)")
        #expect((streamLeft < streamRight) == (left < right), "< \(pair)")
        #expect((streamLeft == right) == (left == right), "== String \(pair)")
        #expect((left == streamRight) == (left == right), "String == \(pair)")
        if left == right {
          #expect(streamLeft.hashValue == streamRight.hashValue, "hash \(pair)")
        }
      }
    }
  }

  @Test
  func `Bytes that are not UTF-8 compare as their repaired text`() {
    // Both repair to a single U+FFFD, the way `String(_:)` reads them.
    let left = self.accumulated([0xFF], chunk: 1)
    let right = self.accumulated([0xFE], chunk: 1)
    expectNoDifference(String(left), String(right))
    expectNoDifference(left == right, true)
    expectNoDifference(left.hashValue, right.hashValue)
    expectNoDifference(left == self.accumulated([0xFF, 0x61], chunk: 1), false)
  }

  // MARK: - Reading

  @Test
  func `Byte offsets slice into decoded substrings`() {
    let head = String(repeating: "x", count: 700)
    let content = head + "the suffix"
    let value = self.accumulated(Array(content.utf8), chunk: 100)
    expectNoDifference(String(value.utf8[700...]), "the suffix")
    expectNoDifference(String(value.utf8[0..<3]), "xxx")
    // A range crossing a block boundary, decoded through the gathering path.
    expectNoDifference(String(value.utf8[510..<514]), "xxxx")
    expectNoDifference(value.utf8[702], UInt8(ascii: "e"))
  }

  @Test
  func `Prefix, suffix and containment match byte wise across block boundaries`() {
    // 500 bytes of padding puts the needle astride the first block seal at 512.
    let value = self.accumulated(
      Array((String(repeating: "p", count: 500) + "needle in a haystack").utf8), chunk: 64
    )
    expectNoDifference(value.hasUTF8Prefix("ppp"), true)
    expectNoDifference(value.hasUTF8Prefix(""), true)
    expectNoDifference(!value.hasUTF8Prefix("q"), true)
    expectNoDifference(value.hasUTF8Suffix("haystack"), true)
    expectNoDifference(value.hasUTF8Suffix(""), true)
    expectNoDifference(!value.hasUTF8Suffix("needle"), true)
    expectNoDifference(value.containsUTF8("needle in"), true)
    expectNoDifference(value.containsUTF8(""), true)
    expectNoDifference(!value.containsUTF8("needle out"), true)
    expectNoDifference(!StreamString().containsUTF8("x"), true)
    // Longer than the content is a plain miss, not a bounds trap.
    expectNoDifference(!StreamString("ab").hasUTF8Prefix("abc"), true)
    expectNoDifference(!StreamString("ab").hasUTF8Suffix("abc"), true)
    // Byte-wise, unlike `==`: an NFD spelling does not match an NFC prefix.
    expectNoDifference(!StreamString("e\u{301}tude").hasUTF8Prefix("\u{E9}"), true)
    expectNoDifference(StreamString("e\u{301}tude") == "\u{E9}tude", true)
  }

  @Test
  func `Byte ranges from search feed decoding doors`() {
    // The first hit sits astride the 512 seal; the second is in the tail.
    let content = String(repeating: "p", count: 508) + "marker middle marker end"
    let value = self.accumulated(Array(content.utf8), chunk: 64)
    let first = value.utf8Range(of: "marker")
    expectNoDifference(first, 508..<514)
    expectNoDifference(String(value.utf8[first!]), "marker")
    expectNoDifference(Substring(value.utf8[first!]), "marker")
    let second = value.utf8Range(of: "marker", from: first!.upperBound)
    expectNoDifference(second, 522..<528)
    expectNoDifference(value.utf8Range(of: "marker", from: second!.upperBound), nil)
    expectNoDifference(value.utf8Range(of: "absent"), nil)
    expectNoDifference(value.utf8Range(of: "end")?.upperBound, value.utf8Count)
    expectNoDifference(value.utf8Range(of: ""), 0..<0)
    expectNoDifference(value.utf8Range(of: "", from: 5), 5..<5)
    expectNoDifference(value.utf8Range(of: "longer than the tail", from: value.utf8Count), nil)
    // Byte-wise honesty: the search lands mid-cluster inside a decomposed character.
    let decomposed = StreamString("e\u{301}!")
    expectNoDifference(decomposed.utf8Range(of: "e"), 0..<1)
    expectNoDifference(decomposed.utf8Range(of: "!"), 3..<4)
  }

  @Test
  func `Substrings bridge into the StringProtocol world`() {
    let content = String(repeating: "bridge ", count: 100)
    let value = self.accumulated(Array(content.utf8), chunk: 32)
    expectNoDifference(Substring(value), content[...])
    expectNoDifference(Substring(value.utf8[0..<6]), "bridge")
    func generic(_ text: some StringProtocol) -> Int { text.count }
    expectNoDifference(generic(Substring(value)), content.count)
  }

  @Test
  func `Unicode scalars agree with String in both directions`() {
    // Multi-byte scalars pushed astride the first block seal at 512.
    let content = String(repeating: "a", count: 509) + "€é✓𝄞 plain tail"
    let value = self.accumulated(Array(content.utf8), chunk: 64)
    let view = value.unicodeScalars
    expectNoDifference(Array(view), Array(content.unicodeScalars))
    var backward = [Unicode.Scalar]()
    var index = view.endIndex
    while index > view.startIndex {
      index = view.index(before: index)
      backward.append(view[index])
    }
    expectNoDifference(backward.reversed(), Array(content.unicodeScalars))
  }

  @Test
  func `Ill-formed bytes decode as one replacement scalar per byte`() {
    let value = self.accumulated([0x61, 0xFF, 0x80, 0x62], chunk: .max)
    expectNoDifference(Array(value.unicodeScalars), ["a", "\u{FFFD}", "\u{FFFD}", "b"])
    expectNoDifference(value.unicodeScalars.index(before: 3), 2)
  }

  // `[E2 82]` is the start of a three-byte sequence cut short by `b`: `String` repairs it as one
  // U+FFFD, not one per byte, and the views claim to repair as `String` does.
  @Test(arguments: [
    [0x61, 0xE2, 0x82, 0x62], [0x61, 0xF0, 0x9F, 0x98, 0x62], [0x61, 0xF0, 0x9F], [0xE2, 0x82],
    [0x65, 0xCC, 0x81, 0xFF], [0xFF, 0xCC, 0x81, 0x61], [0x61, 0xFF, 0x80, 0x62],
  ] as [[UInt8]])
  func `Ill-formed bytes repair as String repairs them`(bytes: [UInt8]) {
    let value = self.accumulated(bytes, chunk: .max)
    let repaired = String(decoding: bytes, as: UTF8.self)
    expectNoDifference(Array(value.unicodeScalars), Array(repaired.unicodeScalars))
    expectNoDifference(Array(value.characters), Array(repaired))
    var backward = [Unicode.Scalar]()
    var index = value.unicodeScalars.endIndex
    while index > value.unicodeScalars.startIndex {
      index = value.unicodeScalars.index(before: index)
      backward.append(value.unicodeScalars[index])
    }
    expectNoDifference(backward.reversed(), Array(repaired.unicodeScalars))
  }

  @Test
  func `Character Sequence Agrees With String, Clusters Included`() {
    // The family emoji is 25 bytes and the flag is a regional-indicator pair. Padding puts both
    // across block boundaries while the sequence still yields the same Character values as
    // String iteration.
    let content = String(repeating: "x", count: 505) + "e\u{301}👨‍👩‍👧‍👦🇺🇸 end"
    let value = self.accumulated(Array(content.utf8), chunk: 32)
    expectNoDifference(Array(value.characters), Array(content))
  }

  @Test
  func `Appending composes accumulations without materializing`() {
    var value = self.accumulated(Array(String(repeating: "left ", count: 200).utf8), chunk: 64)
    let other = self.accumulated(Array("right".utf8), chunk: 1)
    value.append(other)
    value += " and more"
    value.append(Character("!"))
    expectNoDifference(String(value), String(repeating: "left ", count: 200) + "right and more!")
    let joined = StreamString("a") + StreamString("b")
    expectNoDifference(joined, "ab")
    print("printed", terminator: "", to: &value)
    expectNoDifference(value.hasUTF8Suffix("!printed"), true)
  }

  @Test
  func `Streaming out preserves characters across block cuts`() {
    // A three byte scalar sits astride the 512 seal, so a per-block write would tear it.
    let content = String(repeating: "y", count: 511) + "€ tail"
    let value = self.accumulated(Array(content.utf8), chunk: 128)
    var target = ""
    value.write(to: &target)
    expectNoDifference(target, content)
  }

  @Test
  func `Interpolation builds without an intermediate whole String`() {
    let piece = StreamString("piece")
    let value: StreamString = "a \(piece) of \(42) and \("text"[...])"
    expectNoDifference(value, "a piece of 42 and text")
  }

  @Test
  func `Ordering follows String`() {
    expectNoDifference(StreamString("abc") < StreamString("abd"), true)
    expectNoDifference(StreamString("ab") < StreamString("abc"), true)
    expectNoDifference(!(StreamString("abc") < StreamString("abc")), true)
    // Normalized scalar order: U+00E9 sorts after ASCII, whichever way it is spelled.
    expectNoDifference(StreamString("z") < StreamString("\u{E9}"), true)
    expectNoDifference(StreamString("z") < StreamString("e\u{301}"), true)
    expectNoDifference(!(StreamString("e\u{301}") < StreamString("\u{E9}")), true)
    expectNoDifference([StreamString("b"), "a", "c"].sorted(), ["a", "b", "c"])
  }

  @Test
  func `Debug description quotes like String`() {
    expectNoDifference(StreamString("say \"hi\"\n").debugDescription, "say \"hi\"\n".debugDescription)
  }

  @Test
  func `Invalid UTF-8 decodes repaired rather than trapping`() {
    // Unchecked-mode parses can accumulate invalid bytes, so materialization has to repair.
    let value = self.accumulated([0x61, 0xFF, 0x62], chunk: .max)
    expectNoDifference(String(value), "a\u{FFFD}b")
  }

  @Test
  func `Literal, description and bridging agree`() {
    let value: StreamString = "spelled as a literal"
    expectNoDifference(value.description, "spelled as a literal")
    expectNoDifference(String(value), "spelled as a literal")
    expectNoDifference("spelled as a literal".streamPartialValue, value)
  }

  @Test
  func `Codable round trips through the string it stands in for`() throws {
    let value = StreamString(String(repeating: "codable content ", count: 80))
    let encoded = try JSONEncoder().encode(value)
    let expected = try JSONEncoder().encode(String(value))
    expectNoDifference(encoded, expected)
    let decoded = try JSONDecoder().decode(StreamString.self, from: encoded)
    expectNoDifference(decoded, value)
  }

  // MARK: - Parsing

  @Test(arguments: [1, 16, Int.max])
  func `A parsed string field accumulates into a StreamString`(chunk: Int) throws {
    var value = StringFieldModel.Partial()
    let body = String(repeating: "escaped\\nline ", count: 120)
    try parsePartial(
      #"{"title":"The Title","body":"\#(body)"}"#, into: &value, chunk: chunk
    )
    expectNoDifference(value.title, "The Title")
    expectNoDifference(
      value.body.map(String.init), body.replacingOccurrences(of: "\\n", with: "\n") as String?
    )
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
    expectNoDifference(snapshot.body, "first half")
    expectNoDifference(final.body, "first half|second half")
  }
}

@Test(arguments: [63, 64, 65])
func `Values Around The Small Storage Boundary Preserve Value Semantics`(count: Int) {
  let content = String(repeating: "s", count: count)
  var value = StreamString(content)
  let snapshot = value
  value.append("!")
  expectNoDifference(String(snapshot), content)
  expectNoDifference(String(value), content + "!")
}

@Test
func `Reserved And Incrementally Accumulated Values Compare And Hash Equally`() {
  var reserved = StreamString()
  reserved.streamReserve(utf8ByteCount: 128)
  reserved.append("short value")
  var incremental = StreamString()
  for byte in "short value".utf8 {
    withUnsafePointer(to: byte) { pointer in
      let buffer = UnsafeBufferPointer(start: pointer, count: 1)
      incremental.streamAppend(utf8: Span(_unsafeElements: buffer))
    }
  }
  expectNoDifference(reserved, incremental)
  expectNoDifference(reserved.hashValue, incremental.hashValue)
}

@Test(arguments: [1_200, 2_750, 3_500, 1_000_000])
func `Adaptive Reservations Preserve Canonical Value Behavior`(hint: Int) {
  let content = String(repeating: "adaptive 🦎 block content | ", count: 400)
  let canonical = StreamString(content)

  var shortReserved = StreamString()
  shortReserved.streamReserve(utf8ByteCount: hint)
  shortReserved.append("short")
  expectNoDifference(shortReserved, StreamString("short"))
  expectNoDifference(shortReserved.hashValue, StreamString("short").hashValue)

  var reserved = StreamString()
  reserved.streamReserve(utf8ByteCount: hint)
  reserved.append(content)

  expectNoDifference(reserved, canonical)
  expectNoDifference(reserved.hashValue, canonical.hashValue)
  expectNoDifference(String(reserved), content)
  expectNoDifference(reserved.hasUTF8Prefix("adaptive 🦎"), true)
  expectNoDifference(reserved.hasUTF8Suffix("content | "), true)
  expectNoDifference(reserved.utf8Range(of: "🦎 block"), canonical.utf8Range(of: "🦎 block"))

  let snapshot = reserved
  reserved.append("after snapshot")
  expectNoDifference(snapshot, canonical)
  expectNoDifference(reserved > snapshot, true)
}

// The unhinted doubling schedule seals blocks at 512, 1K, 2K, 4K and 8K, then 8K forever, so
// its boundaries sit at 512, 1536, 3584, 7680, 15872, 24064, ... — every one a multiple of 512
// but no longer evenly spaced. These pin reads, slices and search across the uneven boundaries.
@Test(arguments: [1, 77, 512, 8_192, Int.max])
func `Content Growing Past The Block Cap Reads Back Whole`(chunk: Int) {
  // ~40 KB: the whole ramp plus several capped blocks.
  let content = (0..<40_000).map { UInt8(33 + ($0 % 90)) }
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
  expectNoDifference(value.utf8Count, content.count)
  expectNoDifference(String(value), String(decoding: content, as: UTF8.self))
  for boundary in [511, 512, 1_535, 1_536, 3_583, 3_584, 7_679, 7_680, 15_871, 15_872, 24_064] {
    expectNoDifference(value.utf8[boundary], content[boundary])
  }
}

@Test
func `Slices And Search Cross Uneven Block Boundaries`() {
  var text = String(repeating: "x", count: 3_580) + "needle one"
  text += String(repeating: "y", count: 15_866 - text.utf8.count) + "needle two"
  text += String(repeating: "z", count: 500)
  var value = StreamString()
  let bytes = Array(text.utf8)
  bytes.withUnsafeBufferPointer { buffer in
    var offset = 0
    while offset < buffer.count {
      let count = min(97, buffer.count - offset)
      let slice = UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: count)
      value.streamAppend(utf8: Span(_unsafeElements: slice))
      offset += count
    }
  }
  // "needle one" spans the 3584 boundary; "needle two" spans the 15872 boundary.
  let first = value.utf8Range(of: "needle one")
  let second = value.utf8Range(of: "needle two")
  expectNoDifference(first, 3_580..<3_590)
  expectNoDifference(second, 15_866..<15_876)
  expectNoDifference(String(value.utf8[first!]), "needle one")
  expectNoDifference(String(value.utf8[second!]), "needle two")
  expectNoDifference(value.containsUTF8("needle two"), true)
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
  expectNoDifference(low < high, true)
  expectNoDifference(!(high < low), true)
}
