import Testing

import StreamParsingCore
import StreamParsingShims

// On arm64 an escaped string value's tail is taken 64 bytes at a time by
// `stream_parsing_unescape_blocks` (Unescape.c) wherever at least 140 bytes of the chunk lie ahead,
// and by the per-run loop everywhere else. The block kernel has its own copy of the escape table,
// its own `\uXXXX` decoder, its own driver for the UTF-8 lookup (one vector placed at a block's
// non-ASCII bytes, four when they are spread out, none in ASCII text), and edges of its own: a
// backslash as a block's last byte, a `\u` escape or a surrogate pair across one, an escaped quote
// or backslash, a multi-byte sequence across a block boundary or across any of the points where
// it hands the value back -- the chunk's last bytes, a full buffer, a kilobyte without an escape.
//
// The oracle is the per-run loop itself, reached by feeding the same document in pieces too small
// for a block to be taken (one byte per call, as in `Coalesced string chunk tests`, whose recorder
// and folding these tests reuse). Every document is checked whole, at a ladder of chunk sizes that
// straddle the kernel's entry bound, and cut in two at every offset. Each of the kernel's branches
// was removed or bent in turn while these were written (seventeen mutations); every one fails
// here.
@Suite
struct `Escaped tail block tests` {
  typealias Coalesced = `Coalesced string chunk tests`

  // SplitMix64: the documents must be the same on every run and every platform.
  struct Generator {
    var state: UInt64
    mutating func next() -> UInt64 {
      self.state &+= 0x9E37_79B9_7F4A_7C15
      var z = self.state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(self.next() % UInt64(bound)) }
  }

  // What a parse made of a document, with chunk boundaries removed: the content of every string
  // value concatenated, everything else in order, and the error.
  struct Outcome: Equatable {
    var events: [Coalesced.Event]
    var error: JSONParsingError?
  }

  static func outcome(_ events: [Coalesced.Tagged], _ error: JSONParsingError?) -> Outcome {
    var out = [Coalesced.Event]()
    var run: [UInt8]?
    for tagged in events {
      if case .stringChunk(let bytes) = tagged.event {
        if run == nil { run = [] }
        run!.append(contentsOf: bytes)
        continue
      }
      if let bytes = run { out.append(.stringChunk(bytes)) }
      run = nil
      out.append(tagged.event)
    }
    if let bytes = run { out.append(.stringChunk(bytes)) }
    return Outcome(events: out, error: error)
  }

  // The document in two calls, cut at `offset`.
  static func split(_ bytes: [UInt8], at offset: Int, bufferCapacity: Int = 4096) -> Outcome {
    var sink = Coalesced.RecordingSink()
    var parser = JSONParser(bufferCapacity: bufferCapacity)
    var error: JSONParsingError?
    do {
      try bytes.withUnsafeBufferPointer { input throws(JSONParsingError) in
        try parser.parse(UnsafeBufferPointer(rebasing: input[..<offset]), into: &sink)
        try parser.parse(UnsafeBufferPointer(rebasing: input[offset...]), into: &sink)
      }
      try parser.finish(into: &sink)
    } catch let caught {
      error = caught
    }
    return Self.outcome(sink.events, error)
  }

  static func uniform(_ bytes: [UInt8], chunk: Int, bufferCapacity: Int = 4096) -> Outcome {
    let recorded = Coalesced.record(bytes, chunk: chunk, bufferCapacity: bufferCapacity)
    return Self.outcome(recorded.events, recorded.error)
  }

  // A parse that fails has delivered whatever it flushed before the failure, and where the flushes
  // fall is not promised, so a failing parse is held to the error and to having delivered no more
  // than the oracle did.
  static func agree(_ candidate: Outcome, _ oracle: Outcome) -> Bool {
    guard candidate.error == oracle.error else { return false }
    if oracle.error == nil { return candidate.events == oracle.events }
    guard candidate.events.count <= oracle.events.count else { return false }
    for (index, event) in candidate.events.enumerated() {
      if event == oracle.events[index] { continue }
      guard index == candidate.events.count - 1,
        case .stringChunk(let got) = event,
        case .stringChunk(let expected) = oracle.events[index],
        expected.starts(with: got)
      else { return false }
    }
    return true
  }

  static func expectAgreement(
    _ bytes: [UInt8], _ label: String, everySplit: Bool = true, bufferCapacities: [Int] = [4096]
  ) {
    let oracle = Self.uniform(bytes, chunk: 1)
    for capacity in bufferCapacities {
      for chunk in [Int.max, 130, 139, 140, 141, 144, 193, 257, 1000]
      where chunk == .max || chunk < bytes.count {
        let got = Self.uniform(bytes, chunk: chunk, bufferCapacity: capacity)
        guard Self.agree(got, oracle) else {
          Issue.record(
            "\(label): chunk \(chunk), buffer \(capacity): error \(String(describing: got.error)) vs \(String(describing: oracle.error))"
          )
          return
        }
      }
      guard everySplit else { continue }
      for offset in 0...bytes.count {
        let got = Self.split(bytes, at: offset, bufferCapacity: capacity)
        guard Self.agree(got, oracle) else {
          Issue.record(
            "\(label): split at \(offset), buffer \(capacity): error \(String(describing: got.error)) vs \(String(describing: oracle.error))"
          )
          return
        }
      }
    }
  }

  static let simpleSelectors = Array(#""\/bfnrt"#.utf8)
  static let hexDigits = Array("0123456789abcdefABCDEF".utf8)

  static func appendUnicodeEscape(_ value: UInt32, to out: inout [UInt8], _ rng: inout Generator) {
    out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u")])
    for shift in [12, 8, 4, 0] {
      let digit = Int((value >> UInt32(shift)) & 0xF)
      // Either case for a letter digit.
      out.append(digit >= 10 && rng.below(2) == 0 ? Self.hexDigits[digit + 6] : Self.hexDigits[digit])
    }
  }

  // String content: runs of text between escapes, with the run lengths, the escape mix and the
  // share of non-ASCII text all drawn per document so that some documents are escape after escape
  // and some are long clean runs with one escape in a block.
  static func content(_ rng: inout Generator, count: Int) -> [UInt8] {
    var out = [UInt8]()
    let longestRun = [1, 3, 14, 40, 150][rng.below(5)]
    let unicodeShare = [0, 0, 1, 5][rng.below(4)]
    let nonASCIIShare = [0, 0, 2, 9][rng.below(4)]
    while out.count < count {
      for _ in 0..<rng.below(longestRun + 1) {
        if rng.below(10) < nonASCIIShare {
          let scalars: [UInt32] = [0xE9, 0x7FF, 0x800, 0x20AC, 0xFFFD, 0x1_0000, 0x1_F600, 0x10_FFFF]
          out.append(contentsOf: Array(String(Unicode.Scalar(scalars[rng.below(scalars.count)])!).utf8))
        } else {
          // Printable ASCII other than the quote and the backslash.
          var byte = UInt8(0x20 + rng.below(0x5F))
          if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") { byte = UInt8(ascii: "x") }
          out.append(byte)
        }
      }
      for _ in 0..<(1 + rng.below(3)) {
        if rng.below(10) < unicodeShare {
          if rng.below(3) == 0 {
            Self.appendUnicodeEscape(0xD800 + UInt32(rng.below(0x400)), to: &out, &rng)
            Self.appendUnicodeEscape(0xDC00 + UInt32(rng.below(0x400)), to: &out, &rng)
          } else {
            let values: [UInt32] = [0x41, 0x0, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF]
            Self.appendUnicodeEscape(values[rng.below(values.count)], to: &out, &rng)
          }
        } else {
          out.append(UInt8(ascii: "\\"))
          out.append(Self.simpleSelectors[rng.below(Self.simpleSelectors.count)])
        }
      }
    }
    return out
  }

  static func document(_ content: [UInt8]) -> [UInt8] {
    Array(#"{"k":""#.utf8) + content + Array(#"","n":1}"#.utf8)
  }

  @Test
  func `Random escape-dense values agree with the per-run loop at every split`() {
    var rng = Generator(state: 0x5EED_0001)
    for index in 0..<120 {
      let bytes = Self.document(Self.content(&rng, count: 140 + rng.below(520)))
      Self.expectAgreement(bytes, "document \(index)")
    }
  }

  // Long enough to fill the buffer several times over, so the kernel runs out of target room and
  // the tail flushes mid-value; and small buffers, down to ones no block fits in.
  @Test
  func `Values longer than the buffer agree with the per-run loop`() {
    var rng = Generator(state: 0x5EED_0002)
    for index in 0..<12 {
      let bytes = Self.document(Self.content(&rng, count: 9000 + rng.below(6000)))
      Self.expectAgreement(
        bytes, "long document \(index)", everySplit: false,
        bufferCapacities: [4096, 16, 139, 140, 141, 200, 300]
      )
    }
    for index in 0..<24 {
      let bytes = Self.document(Self.content(&rng, count: 300 + rng.below(500)))
      Self.expectAgreement(
        bytes, "small buffer document \(index)", bufferCapacities: [16, 139, 140, 191, 256]
      )
    }
  }

  // The kernel gives a value back to the per-run loop after sixteen blocks without an escape, in
  // the middle of a run, and takes it again once that run has ended. Runs of up to 1,800 bytes
  // with a multi-byte character every so often put a sequence across the block where it lets go
  // -- the bytes of a cut sequence must go back with it -- and, in the second half, an invalid
  // byte somewhere in such a run must be named by the loop exactly as before.
  @Test
  func `Long runs between escapes agree with the per-run loop`() {
    var rng = Generator(state: 0x5EED_0003)
    let characters = ["\u{E9}", "\u{20AC}", "\u{1F600}"].map { Array($0.utf8) }
    for index in 0..<160 {
      var content = Array(#"\n"#.utf8)
      let spacing = [7, 23, 61, 200][rng.below(4)]
      for _ in 0..<(2 + rng.below(3)) {
        let length = 300 + rng.below(1500)
        var run = [UInt8]()
        while run.count < length {
          run += [UInt8](repeating: UInt8(ascii: "q"), count: rng.below(spacing + 1))
          run += characters[rng.below(characters.count)]
        }
        content += run
        content += Array(#"\"\t"#.utf8)
      }
      if index >= 80 {
        content[2 + rng.below(content.count - 4)] = [0xFF, 0x80, 0xC3, 0xED, 0xF4][rng.below(5)]
      }
      Self.expectAgreement(Self.document(content), "long runs \(index)", everySplit: false)
    }
  }

  // The kernel's escape table against the per-run loop's: every byte as a selector, at every
  // position of a block (the 63rd makes it the next block's first byte).
  @Test
  func `Every selector byte decodes or fails as the per-run loop has it`() {
    let filler = [UInt8](repeating: UInt8(ascii: "a"), count: 200)
    for selector in 0...255 {
      for lead in [0, 1, 62, 63, 64, 65] {
        let content =
          [UInt8(ascii: "\\"), UInt8(ascii: "n")] + filler[..<lead]
          + [UInt8(ascii: "\\"), UInt8(selector)] + filler
        Self.expectAgreement(
          Self.document(content), "selector \(selector) after \(lead)", everySplit: false
        )
      }
    }
  }

  // `\uXXXX` in the kernel: decoded where it lies in a block, across a block's last byte (the one
  // place the kernel's input cursor follows the data), as a surrogate pair in one block or two;
  // and left alone, for the per-escape path's diagnostic, when a digit is not one or a surrogate
  // has no partner. Each at every offset against the block, between text of both kinds.
  @Test(arguments: [0, 1])
  func `Unicode escapes decode or fail as the per-run loop has them at every block offset`(
    kind: Int
  ) {
    let escapes: [String] = [
      #"\u0041"#, #"\u0000"#, #"\u007f"#, #"\u0080"#, #"\u07FF"#, #"\u0800"#, #"\uD7ff"#, #"\uE000"#,
      #"\uFFFF"#, #"\ud83d\ude00"#, #"\uD800\uDC00"#, #"\uDBFF\uDFFF"#, #"\u00e9\u00E9\u20ac"#,
      #"\u0041\n\u0042\"\u0043"#, #"\ud83d\ude00\ud83d\ude00\ud83d\ude00"#,
      // Diagnostics: lone and misordered surrogates, bad digits, an escape the value ends inside.
      #"\ud83d"#, #"\ude00"#, #"\ud83dx"#, #"\ud83d\n"#, #"\ud83d\u0041"#, #"\ud83d\ud83d"#,
      #"\ude00\ud83d"#, #"\u00g0"#, #"\ug000"#, #"\u000G"#, #"\u00 0"#, #"\u12"#, #"\u"#,
      #"\ud83d\ude0"#, #"\ud83d\ude0g"#, #"\ud83d\Ude00"#, #"\U0041"#,
    ]
    for (which, escape) in escapes.enumerated() {
      for lead in 0..<80 {
        let content =
          Array(#"\t"#.utf8) + Self.filler(lead, kind: kind) + Array(escape.utf8)
          + Self.filler(170, kind: kind)
        Self.expectAgreement(
          Self.document(content), "escape \(which) after \(lead)", everySplit: lead % 16 == 5
        )
      }
    }
  }

  // Text written in `\u` escapes, as `twitterescaped` is: every block full of them, pairs and
  // single units mixed, with the occasional simple escape and literal run.
  @Test
  func `Values dense in unicode escapes agree with the per-run loop`() {
    var rng = Generator(state: 0x5EED_0004)
    for index in 0..<60 {
      var content = Array(#"\n"#.utf8)
      while content.count < 500 + rng.below(900) {
        switch rng.below(12) {
        case 0:
          content += Array(#"\n"#.utf8)
        case 1:
          content += [UInt8](repeating: UInt8(ascii: "w"), count: rng.below(40))
        case 2, 3:
          Self.appendUnicodeEscape(0xD800 + UInt32(rng.below(0x400)), to: &content, &rng)
          Self.appendUnicodeEscape(0xDC00 + UInt32(rng.below(0x400)), to: &content, &rng)
        default:
          Self.appendUnicodeEscape(0x3040 + UInt32(rng.below(0x60)), to: &content, &rng)
        }
      }
      // A third of the documents get a lone surrogate somewhere late.
      if index % 3 == 0 { Self.appendUnicodeEscape(0xDC00, to: &content, &rng) }
      content += [UInt8](repeating: UInt8(ascii: "z"), count: 150)
      Self.expectAgreement(Self.document(content), "dense \(index)", everySplit: index % 10 == 0)
    }
  }

  // An escaped backslash or quote followed by something that would be an escape or a terminator
  // if the selector were not skipped, at every alignment against the block.
  @Test
  func `Escaped backslashes and quotes are content at every block offset`() {
    let tails: [String] = [
      #"\\n"#, #"\\\n"#, #"\\\\n"#, #"\"\""#, #"\\""#, #"\\\"x"#, #"\"\\"#, #"\\\\\\\\"#, #"\\u0041"#,
      #"\\A"#,
    ]
    for (which, tail) in tails.enumerated() {
      for lead in 0..<70 {
        let content =
          Array(#"\t"#.utf8) + [UInt8](repeating: UInt8(ascii: "b"), count: lead) + Array(tail.utf8)
          + [UInt8](repeating: UInt8(ascii: "c"), count: 150)
        // Some tails end the string early; the remainder is then a syntax error, the same one
        // on both paths.
        Self.expectAgreement(
          Self.document(content), "tail \(which) after \(lead)", everySplit: lead % 8 == 0
        )
      }
    }
  }

  // Invalid and awkward UTF-8 at every block offset. The kernel validates one vector placed at a
  // block's first non-ASCII bytes, all four when they are spread out, and nothing in ASCII text
  // far from any; the per-run loop validates each source run whole. They must name the same byte.
  // The text in front of the fragment decides which of the kernel's checks is looking when the
  // fragment arrives, and the text behind it where the *next* block's vector sits -- a sequence
  // cut by a block's last byte is caught there or not at all.
  static let fragments: [[UInt8]] = [
    [0xFF], [0x80], [0xC3], [0xC0, 0x80], [0xE2, 0x82], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80],
    [0xF0, 0x9F, 0x98], [0xE0, 0x80, 0x80], [0xF0, 0x80, 0x80, 0x80], [0xF5, 0x80, 0x80, 0x80],
    [0xC3, UInt8(ascii: "\\"), UInt8(ascii: "n"), 0xA9],
    [0xE2, 0x82, UInt8(ascii: "\\"), UInt8(ascii: "\""), 0xAC],
    [0xE2, UInt8(ascii: "\\"), UInt8(ascii: "u"), 0x30, 0x30, 0x34, 0x31, 0x82, 0xAC],
    // Valid, for the same positions: a sequence straddling a block boundary must pass.
    [0xC3, 0xA9], [0xE2, 0x82, 0xAC], [0xF0, 0x9F, 0x98, 0x80],
    [0xF0, 0x9F, 0x98, 0x80, UInt8(ascii: "\\"), UInt8(ascii: "n"), 0xC3, 0xA9],
    // A control byte, raw.
    [0x0A], [0x1F], [0x00],
  ]

  // `count` bytes of text ending on a character boundary.
  static func filler(_ count: Int, kind: Int) -> [UInt8] {
    switch kind {
    case 0:
      return [UInt8](repeating: UInt8(ascii: "d"), count: count)
    case 1:
      // Three-byte characters throughout: every block is validated in full.
      return [UInt8](repeating: UInt8(ascii: "d"), count: count % 3)
        + Array(String(repeating: "\u{65E5}", count: count / 3).utf8)
    default:
      // A two-byte character every dozen bytes: one vector per block.
      var out = [UInt8]()
      while out.count + 12 <= count { out += Array("0123456789\u{E9}".utf8) }
      return out + [UInt8](repeating: UInt8(ascii: "d"), count: count - out.count)
    }
  }

  @Test(arguments: [0, 1, 2])
  func `Invalid UTF-8 is rejected at the offset the per-run loop reports`(kind: Int) {
    let tails: [[UInt8]] = [
      [UInt8](repeating: UInt8(ascii: "e"), count: 180),
      [UInt8](repeating: UInt8(ascii: "e"), count: 30) + Array("\u{E9}".utf8)
        + [UInt8](repeating: UInt8(ascii: "e"), count: 150),
      Array(String(repeating: "\u{8A9E}", count: 60).utf8),
    ]
    for (which, fragment) in Self.fragments.enumerated() {
      for lead in 0..<140 {
        for (tailIndex, tail) in tails.enumerated() {
          let content = Array(#"\n"#.utf8) + Self.filler(lead, kind: kind) + fragment + tail
          Self.expectAgreement(
            Self.document(content), "fragment \(which) after \(lead), tail \(tailIndex)",
            everySplit: lead % 16 == 0 && tailIndex == 1
          )
        }
      }
    }
  }

  // Non-ASCII text throughout, so every block is validated in full, and a sequence is cut
  // wherever the kernel stops short of the chunk end.
  @Test
  func `Non-ASCII prose with escapes agrees at every split`() {
    let line = "naïve café — 日本語のテキスト 😀 ελληνικά\\n\\\"quoted\\\" \\t"
    let content = Array(String(repeating: line, count: 9).utf8)
    Self.expectAgreement(Self.document(content), "prose")
    // One bad byte late in it.
    for at in [130, 191, 192, 193, 255, 256, 300, content.count - 1] {
      var broken = content
      broken[at] = 0xFE
      Self.expectAgreement(Self.document(broken), "prose broken at \(at)")
    }
  }

  // Runs of three-byte `\u` escapes are decoded four at a time, past the block they start in and
  // as far as the chunk and the buffer allow. A run must give way, at exactly the escape where it
  // stops being one, to whatever comes next: a scalar of another length, a surrogate (paired or
  // not), a digit that is not one, a simple or escaped-backslash escape, the closing quote, text.
  // The run's values sit on both sides of every edge of the range it accepts.
  static let runValues: [UInt32] = [
    0x0800, 0x0FFF, 0x1000, 0x3042, 0x65E5, 0xABCD, 0xCFFF, 0xD000, 0xD7FF, 0xE000, 0xFFFF,
  ]
  static let runBreakers: [String] = [
    #"߿"#, #"é"#, #"A"#, #"\u0000"#, #"😀"#, #"\uD800"#, #"\uDFFF"#,
    #"\u30G2"#, #"\u3 42"#, #"\u304"#, #"\U3042"#, #"\n"#, #"\\u3042"#, #"\""#, "x", "\u{E9}",
    "\"", #"\\uD83D\uDE00"#, #"\u0041\uDE00"#, #"\uDBFF\uDFFF"#,
  ]

  static func run(_ count: Int, _ rng: inout Generator) -> [UInt8] {
    var out = [UInt8]()
    for _ in 0..<count {
      Self.appendUnicodeEscape(Self.runValues[rng.below(Self.runValues.count)], to: &out, &rng)
    }
    return out
  }

  @Test(arguments: [0, 1])
  func `Runs of three-byte unicode escapes give way exactly where they stop`(kind: Int) {
    var rng = Generator(state: 0x5EED_0005 &+ UInt64(kind))
    for (which, breaker) in Self.runBreakers.enumerated() {
      for before in [0, 1, 3, 4, 5, 7, 8, 11, 12, 23, 30] {
        for lead in 0..<(before == 30 ? 64 : 7) {
          let content =
            Array(#"\t"#.utf8) + Self.filler(lead, kind: kind) + Self.run(before, &rng)
            + Array(breaker.utf8) + Self.run(rng.below(30), &rng) + Self.filler(150, kind: kind)
          Self.expectAgreement(
            Self.document(content), "breaker \(which) after \(before) escapes, lead \(lead)",
            everySplit: lead == 5 && before % 4 == 3
          )
        }
      }
    }
  }

  // The kernel keeps its own copy of the UTF-8 validator's three nibble tables, so that it does
  // not take them as arguments; the Swift ones stay the source.
  #if arch(arm64)
    @Test
    func `The kernel's UTF-8 tables are the validator's`() {
      let tables = [streamUTF8PreviousHighTable, streamUTF8PreviousLowTable, streamUTF8CurrentHighTable]
      for (index, table) in tables.enumerated() {
        for nibble in 0..<16 {
          #expect(
            stream_parsing_unescape_utf8_table(Int32(index), Int32(nibble)) == table[nibble],
            "table \(index), nibble \(nibble)"
          )
        }
      }
    }
  #endif

  // A run longer than the buffer and than any chunk: it ends where the chunk's slack or the
  // buffer's room does, mid-run, and the next call picks it up.
  @Test
  func `Long runs of three-byte unicode escapes agree at every buffer and chunk size`() {
    var rng = Generator(state: 0x5EED_0007)
    for index in 0..<16 {
      // The first few short enough to be cut at every offset.
      let count = index < 4 ? 30 + rng.below(40) : 200 + rng.below(1200)
      let content =
        Array(#"\n"#.utf8) + [UInt8](repeating: UInt8(ascii: "r"), count: index * 5)
        + Self.run(count, &rng) + Array(#"\n"#.utf8) + Self.run(rng.below(50), &rng)
        + [UInt8](repeating: UInt8(ascii: "s"), count: 150)
      Self.expectAgreement(
        Self.document(content), "long run \(index)", everySplit: index < 4,
        bufferCapacities: index < 4 ? [4096, 160] : [4096, 16, 139, 140, 141, 160, 200, 300]
      )
    }
  }
}
