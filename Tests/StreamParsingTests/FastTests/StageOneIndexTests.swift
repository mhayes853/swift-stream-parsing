import CustomDump
import Foundation
import Testing

import StreamParsingCore

// Pins the stage-1 window indexer against a scalar reference with the same semantics: one
// entry per unescaped quote, per structural character outside a string, and per scalar byte
// outside a string that directly follows whitespace (a number after a structural byte is not
// indexed; the walk finds it at its cursor); escape parity is positional (an odd-length backslash run
// escapes the byte after it) wherever it occurs, so the two agree on byte soup as well as on
// JSON. The per-block flags are pinned the same way: `needsScan` for a backslash anywhere or
// a control byte inside a string, `nonASCII` for any byte with the high bit set.
@Suite
struct `Stage one index tests` {
  private struct Reference {
    var entries: [UInt32] = []
    var needsScan: [Bool] = []
    var nonASCII: [Bool] = []
  }

  private static func reference(_ bytes: [UInt8]) -> Reference {
    var out = Reference()
    let blocks = (bytes.count + 63) / 64
    out.needsScan = Array(repeating: false, count: blocks)
    out.nonASCII = Array(repeating: false, count: blocks)
    var pendingEscape = false
    var inString = false
    var previousWasWhitespace = false
    for (i, byte) in bytes.enumerated() {
      let block = i / 64
      if byte >= 0x80 { out.nonASCII[block] = true }
      if byte == 0x5C { out.needsScan[block] = true }
      let escaped = pendingEscape
      pendingEscape = byte == 0x5C && !escaped
      let isQuote = byte == 0x22 && !escaped
      let isWhitespace = !inString && [0x20, 0x09, 0x0A, 0x0D].contains(byte)
      if inString {
        if byte < 0x20 { out.needsScan[block] = true }
        if isQuote {
          out.entries.append(UInt32(i))
          inString = false
        }
      } else if isQuote {
        out.entries.append(UInt32(i))
        inString = true
      } else if [0x2C, 0x3A, 0x5B, 0x5D, 0x7B, 0x7D].contains(byte) {
        out.entries.append(UInt32(i))
      } else if !isWhitespace, byte != 0x22, previousWasWhitespace {
        // A scalar byte after whitespace. An escaped quote outside a string is quote class.
        out.entries.append(UInt32(i))
      }
      previousWasWhitespace = isWhitespace
    }
    return out
  }

  private static func kernel(_ bytes: [UInt8]) -> Reference {
    precondition(bytes.count <= 32_768)
    var out = Reference()
    let indices = UnsafeMutablePointer<UInt32>.allocate(capacity: bytes.count + 8)
    let needsScan = UnsafeMutablePointer<UInt64>.allocate(capacity: 8)
    let nonASCII = UnsafeMutablePointer<UInt64>.allocate(capacity: 8)
    defer {
      indices.deallocate()
      needsScan.deallocate()
      nonASCII.deallocate()
    }
    // Poison the bitmaps so the kernel's own clearing is what the comparison sees.
    needsScan.initialize(repeating: .max, count: 8)
    nonASCII.initialize(repeating: .max, count: 8)
    let count = bytes.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return 0 }
      return streamIndexWindow(
        base: UnsafeRawPointer(base), count: buffer.count, baseOffset: 0,
        indices: indices, needsScan: needsScan, nonASCII: nonASCII
      )
    }
    out.entries = Array(UnsafeBufferPointer(start: indices, count: count))
    let blocks = (bytes.count + 63) / 64
    for block in 0..<blocks {
      out.needsScan.append(needsScan[block >> 6] & (1 << UInt64(block & 63)) != 0)
      out.nonASCII.append(nonASCII[block >> 6] & (1 << UInt64(block & 63)) != 0)
    }
    return out
  }

  private static func expectMatch(_ bytes: [UInt8], _ label: String) {
    let expected = Self.reference(bytes)
    let actual = Self.kernel(bytes)
    expectNoDifference(actual.entries, expected.entries, "\(label): entries")
    expectNoDifference(actual.needsScan, expected.needsScan, "\(label): needsScan")
    expectNoDifference(actual.nonASCII, expected.nonASCII, "\(label): nonASCII")
  }

  @Test
  func `Corpus files index like the reference`() throws {
    for name in ["64KB", "DeepNested64"] {
      let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
      var bytes = Array(try Data(contentsOf: url))
      if bytes.count > 32_768 { bytes.removeSubrange(32_768...) }
      Self.expectMatch(bytes, name)
    }
  }

  // Backslash runs of every parity crossing the 64- and 128-byte block boundaries, which is
  // where the escape carry and the quote parity carry both have to be right.
  @Test
  func `Backslash runs across block boundaries`() {
    for runLength in 0..<140 {
      var bytes = Array("{\"k\":\"a".utf8)
      bytes.append(contentsOf: repeatElement(0x5C, count: runLength))
      bytes.append(contentsOf: Array("n b\"}".utf8))
      Self.expectMatch(bytes, "run \(runLength)")
    }
  }

  // Quotes landing on every position around the block boundaries, with content on both sides.
  @Test
  func `Quotes at every offset around a block boundary`() {
    for lead in 50..<80 {
      var bytes = Array(repeating: UInt8(ascii: " "), count: lead)
      bytes.append(contentsOf: Array("\"x]y\" , [ \"z\"".utf8))
      Self.expectMatch(bytes, "lead \(lead)")
    }
  }

  @Test
  func `NUL and other control bytes are not whitespace`() {
    // Outside a string a NUL is not an entry (the walk's gap check rejects it); inside a
    // string it flags the block.
    Self.expectMatch([0x5B, 0x00, 0x5D], "nul outside")
    Self.expectMatch(Array("[\"a\u{0}b\"]".utf8), "nul inside")
    Self.expectMatch(Array("[\"a\tb\", \t\n\r 1]".utf8), "tab inside, whitespace outside")
  }

  @Test
  func `Empty and short inputs`() {
    Self.expectMatch([], "empty")
    Self.expectMatch([0x31], "one digit")
    Self.expectMatch(Array("\"\"".utf8), "empty string")
    Self.expectMatch(Array("[]".utf8), "empty array")
  }

  // Deterministic byte soup, weighted toward the bytes the bit algebra can get wrong.
  @Test
  func `Byte soup matches the reference`() {
    var state: UInt64 = 0x5EED_5EED_5EED_5EED
    func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    let special = Array("\\\"{}[]:, \t\n\r0123456789.eEtrufalsn-".utf8)
    for round in 0..<600 {
      let length = Int(next() % 700)
      var bytes = [UInt8]()
      bytes.reserveCapacity(length)
      for _ in 0..<length {
        let roll = next()
        if roll % 4 == 0 {
          bytes.append(UInt8(truncatingIfNeeded: roll >> 8))
        } else {
          bytes.append(special[Int(roll >> 8) % special.count])
        }
      }
      Self.expectMatch(bytes, "soup \(round)")
    }
  }
}
