import CustomDump
import Testing

import StreamParsingCore

// The vector validator is held to the standard library's decoder: a byte string is valid
// exactly when decoding it with repair changes nothing. Both the lookup path the parser uses
// and the compare-based portable path are checked, on the same inputs, at several offsets into
// a larger buffer so the first block, the overlapping middle blocks and the scratch tail are all
// exercised, with a quote before the run the way the parser always has one.
@Suite
struct `UTF-8 validation tests` {
  private static func oracle(_ bytes: [UInt8]) -> Bool {
    Array(String(decoding: bytes, as: UTF8.self).utf8) == bytes
  }

  private static func vector(_ bytes: [UInt8], offset: Int, portable: Bool) -> Bool {
    var buffer = [UInt8](repeating: UInt8(ascii: "\""), count: offset)
    buffer.append(contentsOf: bytes)
    buffer.append(contentsOf: Array(repeating: UInt8(ascii: "\""), count: 4))
    return buffer.withUnsafeBytes { raw in
      let base = raw.baseAddress!
      return portable
        ? streamValidateUTF8Portable(base: base, from: offset, to: offset + bytes.count)
        : streamValidateUTF8(base: base, from: offset, to: offset + bytes.count)
    }
  }

  private static func check(
    _ bytes: [UInt8], offsets: [Int] = [0, 3, 15, 16, 17, 40],
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let expected = Self.oracle(bytes)
    for offset in offsets {
      for portable in [false, true] {
        let actual = Self.vector(bytes, offset: offset, portable: portable)
        if actual != expected {
          Issue.record(
            "\(portable ? "portable" : "lookup") at offset \(offset): expected \(expected) for \(bytes.map { String($0, radix: 16) })",
            sourceLocation: sourceLocation
          )
          return
        }
      }
    }
  }

  @Test
  func `Every two byte sequence`() {
    for first in 0...255 {
      for second in 0...255 {
        Self.check([UInt8(first), UInt8(second)], offsets: [0, 17])
      }
    }
  }

  @Test
  func `Every two byte sequence inside ASCII`() {
    for first in 0x80...255 {
      for second in 0...255 {
        Self.check([0x41, 0x42, UInt8(first), UInt8(second), 0x43], offsets: [0, 3, 15, 16])
      }
    }
  }

  @Test
  func `Three and four byte leads against every second byte`() {
    for lead in 0xE0...0xF7 {
      for second in 0...255 {
        Self.check([UInt8(lead), UInt8(second), 0x80], offsets: [0, 16])
        Self.check([UInt8(lead), UInt8(second), 0x80, 0x80], offsets: [0, 16])
        Self.check([UInt8(lead), UInt8(second), 0x41], offsets: [0, 16])
        Self.check([0x41, UInt8(lead), UInt8(second), 0x80, 0x80, 0x41], offsets: [0, 15])
      }
    }
  }

  @Test
  func `Sequences cut by the end of the run`() {
    Self.check([0xC3])
    Self.check([0xE3, 0x81])
    Self.check([0xF0, 0x9F, 0x98])
    Self.check(Array("abcdefghijklmno".utf8) + [0xE3])
    Self.check(Array("abcdefghijklmn".utf8) + [0xE3, 0x81])
    Self.check(Array("abcdefghijklm".utf8) + [0xF0, 0x9F, 0x98])
    Self.check(Array("abcdefghijklmnop".utf8) + [0xC3])
    Self.check(Array("abcdefghijklmnopq".utf8) + [0xE3, 0x81])
    Self.check(Array("abcdefghijklmnopqrstuvwxyz0123456".utf8) + [0xF0, 0x9F, 0x98])
  }

  @Test
  func `Valid text at every length and one byte corrupted at every position`() {
    let text = Array("日本語のテキスト, émojis 😀🎉, Ωμέγα, עברית, and plain ASCII.".utf8)
    var boundaries = [Int]()
    var index = 0
    for scalar in String(decoding: text, as: UTF8.self).unicodeScalars {
      index += scalar.utf8.count
      boundaries.append(index)
    }
    for end in boundaries {
      Self.check(Array(text[..<end]))
      Self.check(Array(text[..<end]), offsets: [1, 2, 5, 18, 33])
    }
    for position in 0..<text.count {
      for replacement: UInt8 in [0x41, 0x80, 0xBF, 0xC0, 0xE0, 0xED, 0xF4, 0xFF] {
        var corrupted = text
        corrupted[position] = replacement
        Self.check(corrupted, offsets: [0, 7, 16])
      }
      var truncated = Array(text[..<position])
      Self.check(truncated, offsets: [0, 16])
      truncated.append(0x80)
      Self.check(truncated, offsets: [0, 16])
    }
  }

  @Test
  func `Random byte strings`() {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> UInt64 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return state >> 33
    }
    let alphabet: [UInt8] = [
      0x20, 0x41, 0x7E, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF,
      0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF,
      0xF0, 0xF1, 0xF3, 0xF4, 0xF5, 0xF8, 0xFF
    ]
    for _ in 0..<30_000 {
      let count = Int(next() % 80)
      var bytes = [UInt8]()
      bytes.reserveCapacity(count)
      for _ in 0..<count {
        // Mostly plausible structure, with raw alphabet bytes thrown in.
        switch next() % 8 {
        case 0: bytes.append(contentsOf: [0xE3, 0x81, 0x82])
        case 1: bytes.append(contentsOf: [0xF0, 0x9F, 0x98, 0x80])
        case 2: bytes.append(contentsOf: [0xC3, 0xA9])
        case 3: bytes.append(0x41)
        default: bytes.append(alphabet[Int(next() % UInt64(alphabet.count))])
        }
      }
      Self.check(bytes, offsets: [0, 16])
    }
  }
}
