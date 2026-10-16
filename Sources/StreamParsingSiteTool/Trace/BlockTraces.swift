import Foundation
import StreamParsingShims

@testable import StreamParsingCore

/// Recorders for the two arm64 block walks.
///
/// The masks come from the shipped C classifiers. The small mirrors exist only to expose the
/// otherwise-local cursor, mask and carry transitions to the site, and each mirror is checked
/// against the corresponding shipped Swift walk before the bundle is written.
enum BlockTraces {
  static func structural() throws -> StructuralBlockTrace {
    #if arch(arm64)
      let cases = try [
        self.structuralCase(
          name: "indented document",
          purpose: "The ladder signals on the newline after `{`: whitespace followed by more whitespace. A long string crosses byte 64, so the grid re-anchors at its closing quote; every key takes its colon with it; the array's comma hands the indented numbers to fuseNumberRun.",
          sample: """
            {
              "message": "this string crosses the first sixty-four-byte block boundary cleanly",
              "scores": [
                12,
                7,
                31,
                5
              ],
              "active": true,
              "profile": {"id": 42, "ok": null},
              "tail": "done"
            }
            """),
        self.structuralCase(
          name: "handed back",
          purpose: "The first block has indentation and a string, so the walk takes it. The next is minified strings: no whitespace outside a string, nothing for the walk to buy. `ladder_block` hands it back to the ladder, which comes back at the next indentation it meets.",
          sample: "{\n  \"ids\": ["
            + (0..<12).map { "\"id-abcdef\($0)\"" }.joined(separator: ",")
            + "],\n  \"n\": 1\n}")
      ]
      return StructuralBlockTrace(cases: cases, verified: cases.allSatisfy(\.verified))
    #else
      return StructuralBlockTrace(cases: [], verified: true)
    #endif
  }

  static func skip() throws -> SkipBlockTrace {
    #if arch(arm64)
      // Byte 1 is the first byte *inside* the root array the sink declined. The first quoted
      // value contains bracket glyphs which must not enter `brackets`; the second 64-byte block
      // ends inside a string, so the carry handoff is visible as well.
      let sample = """
        [
          {"text":"brackets [inside] strings do not count","items":[1,2,{"x":"y"}]},
          {"text":"a second object keeps the skipped subtree wider than two blocks","ok":true},
          [3,4,5]
        ]
        """
      let bytes = Array(sample.utf8)
      let from = 1
      let startDepth = 1
      let endDepth = 0
      var p = from
      var depth = startDepth
      var containers: UInt64 = 0
      var inString: UInt64 = 0
      var endsOdd: UInt64 = 0
      var blocks: [SkipBlockTrace.Block] = []
      var ended = false

      bytes.withUnsafeBytes { raw in
        let base = raw.baseAddress!
        while !ended, p &+ 64 <= bytes.count {
          let beforeDepth = depth
          let inBefore = inString != 0
          let oddBefore = endsOdd != 0
          let classes = stream_parsing_classify_skip_block(
            base.advanced(by: p).assumingMemoryBound(to: UInt8.self), inString, endsOdd)
          var mask = classes.brackets
          var visits: [SkipBlockTrace.Visit] = []

          if classes.needs_scalar == 0 {
            while mask != 0 {
              let at = p &+ mask.trailingZeroBitCount
              mask &= mask &- 1
              let byte = bytes[at]
              let isObject = byte & 0x20 != 0
              let opens = byte & 0x02 != 0
              let visitDepth = depth
              var emits = false
              if opens {
                if isObject { containers |= 1 &<< UInt64(depth) }
                else { containers &= ~(1 &<< UInt64(depth)) }
                depth &+= 1
              } else if depth &- 1 == endDepth {
                depth &-= 1
                emits = true
                ended = true
              } else {
                depth &-= 1
              }
              visits.append(
                SkipBlockTrace.Visit(
                  offset: at, byte: byte, depthBefore: visitDepth, depthAfter: depth,
                  isObject: isObject, opens: opens, emits: emits,
                  maskAfter: self.maskBits(mask)))
              if ended { break }
            }
          }

          blocks.append(
            SkipBlockTrace.Block(
              index: blocks.count, offset: p, bytes: Array(bytes[p..<(p + 64)]),
              brackets: self.maskBits(classes.brackets), needsScalar: classes.needs_scalar != 0,
              nonASCII: classes.non_ascii != 0, inStringBefore: inBefore,
              inStringAfter: classes.in_string != 0, endsOddBefore: oddBefore,
              endsOddAfter: classes.ends_odd != 0, depthBefore: beforeDepth, depthAfter: depth,
              visits: visits))

          if ended {
            p = visits.last!.offset &+ 1
            break
          }
          if classes.needs_scalar != 0 { break }
          inString = classes.in_string
          endsOdd = classes.ends_odd
          p &+= 64
        }
      }

      let mirroredState = endsOdd != 0 ? "skippingEscape" : (inString != 0 ? "skippingString" : "skipping")

      var parser = JSONParser()
      parser.state = .skipping
      parser.depth = startDepth
      parser.containers = 0
      parser.skipEndDepth = UInt8(endDepth)
      var state = parser.state
      var shippedDepth = parser.depth
      var shippedContainers = parser.containers
      var sink = RecordingSink()
      let shippedEnd = try bytes.withUnsafeBytes { raw -> Int in
        sink.base = raw.baseAddress
        sink.count = bytes.count
        return try parser.consumeSkipBlocks(
          base: raw.baseAddress!, from: from, to: bytes.count, state: &state,
          depth: &shippedDepth, containers: &shippedContainers, into: &sink)
      }
      let shippedState = self.skipStateName(state)
      let verified = p == shippedEnd && depth == shippedDepth && containers == shippedContainers
        && mirroredState == shippedState

      return SkipBlockTrace(
        sample: sample, bytes: bytes, from: from, startDepth: startDepth, blocks: blocks, end: p,
        shippedEnd: shippedEnd, state: mirroredState, shippedState: shippedState,
        verified: verified)
    #else
      return SkipBlockTrace(
        sample: "", bytes: [], from: 0, startDepth: 0, blocks: [], end: 0, shippedEnd: 0,
        state: "unavailable", shippedState: "unavailable", verified: true)
    #endif
  }

  #if arch(arm64)
    private static func structuralCase(name: String, purpose: String, sample: String) throws
      -> StructuralBlockTrace.Case
    {
      let bytes = Array(sample.utf8)
      let entry = try self.signalOffset(bytes)

      // The state the ladder holds when it signals: a scalar parse of everything before the
      // signalled byte. The same parser then runs the shipped walk from there.
      var parser = JSONParser()
      parser.blockWalkEnabled = false
      var prefixSink = RecordingSink()
      try Array(bytes[..<entry]).withUnsafeBufferPointer { buffer in
        try parser.parse(buffer, into: &prefixSink)
      }
      let entryState = String(describing: parser.state)

      var blocks: [StructuralBlockTrace.Block] = []
      var p = entry
      var exit = "tail"
      var depth = parser.depth
      var containers = parser.containers
      var expectsKey = parser.state == .key || parser.state == .firstKey
      // `fuseNumberRun` keeps its indentation prediction in the parser, so the mirror's calls go
      // through one scratch parser, as the shipped walk's go through one.
      var fuser = JSONParser()
      var fuserSink = RecordingSink()

      // A buffer of its own rather than `withUnsafeBytes`: a typed-throws closure around this body
      // crashes the 6.4 SIL ownership verifier.
      let storage = UnsafeMutableRawBufferPointer.allocate(byteCount: bytes.count, alignment: 16)
      defer { storage.deallocate() }
      storage.copyBytes(from: bytes)
      do {
        let base = UnsafeRawPointer(storage.baseAddress!)
        fuserSink.base = base
        fuserSink.count = bytes.count
        outer: while p &+ 64 <= bytes.count {
          let classes = stream_parsing_classify_structural_block(
            base.advanced(by: p).assumingMemoryBound(to: UInt8.self), 0, 0)
          var mask = classes.starts
          var visits: [StructuralBlockTrace.Visit] = []
          var reanchor: Int?
          let outer = self.outerWhitespace(bytes, from: p)
          let takes = classes.needs_scalar == 0 && classes.ladder_block == 0

          if takes {
            while mask != 0 {
              let bit = mask.trailingZeroBitCount
              let at = p &+ bit
              let byte = bytes[at]
              var next = at &+ 1
              var kind = self.structuralKind(byte)
              var fused: String?
              var fusedNumbers = 0
              var stop: String?

              if byte == UInt8(ascii: "\"") {
                let throughOpening = bit == 63 ? UInt64.max : (UInt64(1) &<< UInt64(bit &+ 1)) &- 1
                let closers = classes.quote & ~throughOpening
                let close: Int
                if closers != 0 {
                  close = p &+ closers.trailingZeroBitCount
                } else {
                  close = streamStringRun(base: base, from: at &+ 1, to: bytes.count).end
                }
                next = close &+ 1
                if expectsKey {
                  kind = "key"
                  expectsKey = false
                  // The colon is taken with an in-block key when it sits against the quote.
                  if closers != 0, close &- p != 63, bytes[close &+ 1] == UInt8(ascii: ":") {
                    next = close &+ 2
                    fused = "colon"
                  }
                } else {
                  kind = "string"
                }
              } else if byte == UInt8(ascii: "t") || byte == UInt8(ascii: "n") {
                kind = "literal"
                next = at &+ 4
              } else if byte == UInt8(ascii: "f") {
                kind = "literal"
                next = at &+ 5
              } else if byte == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                kind = "number"
                let ends = classes.scalar_end & (UInt64.max &<< UInt64(bit))
                var end = p &+ ends.trailingZeroBitCount
                if ends == 0 {
                  end = streamNumberRunEnd(base: base, from: end, to: bytes.count)
                  if end >= bytes.count {
                    stop = "tokenCut"
                    end = at
                  }
                }
                next = end
                if stop == nil, depth > 0, end &+ 1 < bytes.count, bytes[end] == UInt8(ascii: ","),
                  !JSONParser.topIsObject(depth: depth, containers: containers)
                {
                  let before = fuserSink.events.count
                  let resume = try fuser.fuseNumberRun(
                    base: base, comma: end, to: bytes.count, into: &fuserSink)
                  if resume < 0 {
                    next = ~resume
                    stop = "tokenCut"
                  } else {
                    next = resume
                  }
                  fusedNumbers = fuserSink.events.count &- before
                  if fusedNumbers > 0 { fused = "numberRun" }
                }
              } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                JSONParser.pushContainer(object: byte == UInt8(ascii: "{"), depth: &depth, containers: &containers)
                expectsKey = byte == UInt8(ascii: "{")
              } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth &-= 1
                if depth == 0 { stop = "done" }
              } else if byte == UInt8(ascii: ",") {
                expectsKey = JSONParser.topIsObject(depth: depth, containers: containers)
              }

              if let stop {
                visits.append(
                  StructuralBlockTrace.Visit(
                    offset: at, byte: byte, kind: kind, next: next,
                    maskAfter: self.maskBits(0), reanchors: false, fused: fused,
                    fusedNumbers: fusedNumbers))
                exit = stop
                blocks.append(self.block(blocks.count, p: p, bytes: bytes, classes: classes, outer: outer, visits: visits))
                p = next
                break outer
              }

              let movesGrid = next &- p >= 64
              if movesGrid {
                mask = 0
                reanchor = next
              } else {
                mask &= UInt64.max &<< UInt64(next &- p)
              }
              visits.append(
                StructuralBlockTrace.Visit(
                  offset: at, byte: byte, kind: kind, next: next,
                  maskAfter: self.maskBits(mask), reanchors: movesGrid, fused: fused,
                  fusedNumbers: fusedNumbers))
              if movesGrid { break }
            }
          }

          blocks.append(self.block(blocks.count, p: p, bytes: bytes, classes: classes, outer: outer, visits: visits))
          if classes.needs_scalar != 0 {
            exit = "needsScalar"
            break outer
          }
          if classes.ladder_block != 0 {
            exit = "ladderBlock"
            break outer
          }
          p = reanchor ?? (p &+ 64)
        }
      }

      var state = parser.state
      var shippedDepth = parser.depth
      var shippedContainers = parser.containers
      var sink = RecordingSink()
      let shippedEnd = try bytes.withUnsafeBytes { raw -> Int in
        sink.base = raw.baseAddress
        sink.count = bytes.count
        return try parser.consumeStructuralBlocks(
          base: raw.baseAddress!, from: entry, to: bytes.count, state: &state, depth: &shippedDepth,
          containers: &shippedContainers, into: &sink)
      }
      let resume = bytes.withUnsafeBytes { raw in
        state.isStructural ? streamWhitespaceEnd(base: raw.baseAddress!, from: p, to: bytes.count) : p
      }

      let blockEvents = try self.parseEvents(bytes, blockWalkEnabled: true)
      let scalarEvents = try self.parseEvents(bytes, blockWalkEnabled: false)
      let eventsMatch = self.eventsEqual(blockEvents, scalarEvents)
      let verified = p == shippedEnd && depth == shippedDepth && eventsMatch

      return StructuralBlockTrace.Case(
        name: name, purpose: purpose, sample: sample, bytes: bytes, entry: entry,
        entryState: entryState, blocks: blocks, end: p, exit: exit, shippedEnd: shippedEnd,
        resume: resume, eventsMatch: eventsMatch, verified: verified)
    }

    /// Where the ladder first signals: a whitespace byte outside a string, followed by the byte
    /// the shipped `signalsBlockWalk` accepts, with a whole block ahead.
    private static func signalOffset(_ bytes: [UInt8]) throws -> Int {
      var inString = false
      var escaped = false
      for i in 0..<(bytes.count &- 64) {
        let byte = bytes[i]
        if inString {
          if escaped { escaped = false }
          else if byte == UInt8(ascii: "\\") { escaped = true }
          else if byte == UInt8(ascii: "\"") { inString = false }
          continue
        }
        if byte == UInt8(ascii: "\"") { inString = true; continue }
        if byte <= 0x20, JSONParser.signalsBlockWalk(byte, bytes[i &+ 1]) { return i }
      }
      struct NoSignal: Error {}
      throw NoSignal()
    }

    private static func outerWhitespace(_ bytes: [UInt8], from p: Int) -> (count: Int, run: Bool) {
      // Quote parity from the grid's first byte, which the walk guarantees is outside a string.
      var inString = false
      var escaped = false
      var count = 0
      var run = false
      var previous = false
      for i in p..<(p &+ 64) {
        let byte = bytes[i]
        var outerSpace = false
        if inString {
          if escaped { escaped = false }
          else if byte == UInt8(ascii: "\\") { escaped = true }
          else if byte == UInt8(ascii: "\"") { inString = false }
        } else if byte == UInt8(ascii: "\"") {
          inString = true
        } else if streamIsWhitespace(byte) {
          outerSpace = true
          count &+= 1
          if previous { run = true }
        }
        previous = outerSpace
      }
      return (count, run)
    }

    private static func block(
      _ index: Int, p: Int, bytes: [UInt8], classes: stream_parsing_structural_classes,
      outer: (count: Int, run: Bool), visits: [StructuralBlockTrace.Visit]
    ) -> StructuralBlockTrace.Block {
      StructuralBlockTrace.Block(
        index: index, offset: p, bytes: Array(bytes[p..<(p + 64)]),
        starts: self.maskBits(classes.starts), quotes: self.maskBits(classes.quote),
        backslashes: self.maskBits(classes.backslash), scalarEnds: self.maskBits(classes.scalar_end),
        startCount: classes.starts.nonzeroBitCount, outerWhitespace: outer.count,
        outerWhitespaceRun: outer.run, ladderBlock: classes.ladder_block != 0,
        nonASCII: classes.non_ascii != 0, needsScalar: classes.needs_scalar != 0, visits: visits)
    }

    private static func parseEvents(_ bytes: [UInt8], blockWalkEnabled: Bool) throws
      -> [RecordingSink.Event]
    {
      var parser = JSONParser()
      parser.blockWalkEnabled = blockWalkEnabled
      var sink = RecordingSink()
      try bytes.withUnsafeBufferPointer { buffer in
        sink.base = UnsafeRawPointer(buffer.baseAddress!)
        sink.count = buffer.count
        try parser.parse(buffer, into: &sink)
      }
      try parser.finish(into: &sink)
      return sink.events
    }

    private static func eventsEqual(_ lhs: [RecordingSink.Event], _ rhs: [RecordingSink.Event]) -> Bool {
      guard lhs.count == rhs.count else { return false }
      return zip(lhs, rhs).allSatisfy { a, b in
        a.kind == b.kind && a.text == b.text && a.spanOffset == b.spanOffset
          && a.spanLength == b.spanLength
      }
    }

    private static func structuralKind(_ byte: UInt8) -> String {
      switch byte {
      case UInt8(ascii: "{"): return "open object"
      case UInt8(ascii: "["): return "open array"
      case UInt8(ascii: "}"): return "close object"
      case UInt8(ascii: "]"): return "close array"
      case UInt8(ascii: ":"): return "colon"
      case UInt8(ascii: ","): return "comma"
      default: return "token"
      }
    }

    private static func skipStateName(_ state: JSONParser.State) -> String {
      switch state {
      case .skipping: return "skipping"
      case .skippingString: return "skippingString"
      case .skippingEscape: return "skippingEscape"
      case .done: return "done"
      case .afterValue: return "afterValue"
      default: return "state-\(state.rawValue)"
      }
    }

    private static func maskBits(_ mask: UInt64) -> [Bool] {
      (0..<64).map { mask & (UInt64(1) &<< UInt64($0)) != 0 }
    }
  #endif
}
