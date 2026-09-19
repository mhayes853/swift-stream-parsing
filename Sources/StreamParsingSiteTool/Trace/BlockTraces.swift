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
          name: "moving grid",
          purpose: "A long string crosses byte 64. Its own scanner finishes it, then the next 64-byte grid starts at the closing quote instead of re-reading the string interior.",
          sample: """
            {
              "message": "this string crosses the first sixty-four-byte block boundary cleanly",
              "items": [1, 2, 3],
              "active": true,
              "profile": {"id": 42, "ok": null},
              "tail": "done"
            }
            """),
        self.structuralCase(
          name: "four strikes",
          purpose: "Compact strings contain no whitespace outside strings. Four consecutive classified blocks make the parser leave the block walk for the scalar copy.",
          sample: "[" + Array(repeating: "\"abcdefghij\"", count: 28).joined(separator: ",") + "]")
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
      var blocks: [StructuralBlockTrace.Block] = []
      var p = 0
      var strikes = 0
      var gaveUp = false

      bytes.withUnsafeBytes { raw in
        let base = raw.baseAddress!
        outer: while p &+ 64 <= bytes.count {
          let classes = stream_parsing_classify_structural_block(
            base.advanced(by: p).assumingMemoryBound(to: UInt8.self), 0, 0)
          let before = strikes
          if classes.no_outer_whitespace != 0 || classes.starts.nonzeroBitCount >= 48 {
            strikes &+= 1
          } else if strikes != 0 {
            strikes = 0
          }
          let stopsAtGate = strikes >= 4
          var mask = classes.starts
          var visits: [StructuralBlockTrace.Visit] = []
          var reanchor: Int?

          if classes.needs_scalar == 0 && !stopsAtGate {
            while mask != 0 {
              let bit = mask.trailingZeroBitCount
              let at = p &+ bit
              let byte = bytes[at]
              var next = at &+ 1
              var kind = self.structuralKind(byte)

              if byte == UInt8(ascii: "\"") {
                kind = "quoted token"
                let throughOpening = bit == 63 ? UInt64.max : (UInt64(1) &<< UInt64(bit &+ 1)) &- 1
                let closers = classes.quote & ~throughOpening
                if closers != 0 {
                  next = p &+ closers.trailingZeroBitCount &+ 1
                } else {
                  let run = streamStringRun(base: base, from: at &+ 1, to: bytes.count)
                  next = min(run.end &+ 1, bytes.count)
                }
              } else if byte == UInt8(ascii: "t") || byte == UInt8(ascii: "n") {
                kind = "literal"
                next = at &+ 4
              } else if byte == UInt8(ascii: "f") {
                kind = "literal"
                next = at &+ 5
              } else if byte == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                kind = "number"
                next = streamNumberRunEnd(base: base, from: at, to: bytes.count)
              }

              let movesGrid = next &- p >= 64
              if movesGrid {
                mask = 0
                reanchor = next
              } else if next == at &+ 1 {
                mask &= mask &- 1
              } else {
                mask &= UInt64.max &<< UInt64(next &- p)
              }
              visits.append(
                StructuralBlockTrace.Visit(
                  offset: at, byte: byte, kind: kind, next: next,
                  maskAfter: self.maskBits(mask), reanchors: movesGrid))
              if movesGrid { break }
            }
          }

          blocks.append(
            StructuralBlockTrace.Block(
              index: blocks.count, offset: p, bytes: Array(bytes[p..<(p + 64)]),
              starts: self.maskBits(classes.starts), quotes: self.maskBits(classes.quote),
              backslashes: self.maskBits(classes.backslash),
              startCount: classes.starts.nonzeroBitCount,
              noOuterWhitespace: classes.no_outer_whitespace != 0,
              nonASCII: classes.non_ascii != 0, needsScalar: classes.needs_scalar != 0,
              strikeBefore: before, strikeAfter: strikes, givesUp: stopsAtGate, visits: visits))

          if classes.needs_scalar != 0 { break outer }
          if stopsAtGate {
            gaveUp = true
            break outer
          }
          p = reanchor ?? (p &+ 64)
        }
      }

      var parser = JSONParser()
      var state = parser.state
      var depth = parser.depth
      var containers = parser.containers
      var sink = RecordingSink()
      let shippedResult = try bytes.withUnsafeBytes { raw -> Int in
        sink.base = raw.baseAddress
        sink.count = bytes.count
        return try parser.consumeStructuralBlocks(
          base: raw.baseAddress!, from: 0, to: bytes.count, state: &state, depth: &depth,
          containers: &containers, into: &sink)
      }
      let shippedGaveUp = shippedResult < 0
      let shippedEnd = shippedGaveUp ? ~shippedResult : shippedResult

      let blockEvents = try self.parseEvents(bytes, blockWalkEnabled: true)
      let scalarEvents = try self.parseEvents(bytes, blockWalkEnabled: false)
      let eventsMatch = self.eventsEqual(blockEvents, scalarEvents)
      let verified = p == shippedEnd && gaveUp == shippedGaveUp && eventsMatch

      return StructuralBlockTrace.Case(
        name: name, purpose: purpose, sample: sample, bytes: bytes, blocks: blocks, end: p,
        shippedEnd: shippedEnd, gaveUp: gaveUp, shippedGaveUp: shippedGaveUp,
        eventsMatch: eventsMatch, verified: verified)
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
