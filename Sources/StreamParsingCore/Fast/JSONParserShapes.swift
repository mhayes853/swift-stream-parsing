// Shape loops for the windowed walk. A shape loop commits to a pattern the index makes visible
// ahead of time — a run of entries whose kinds are known before they are consumed — and
// processes it without the state machine: no state variable, no per-token switch, extents read
// straight from the index. It is speculative by construction: every element is pattern-checked
// before any sink call or state change for it, and the first element off the pattern returns
// control to `consumeWindow`, which resumes its exact machine from a well-defined position.
// The loops therefore never throw a grammar error themselves; whatever is malformed is handed
// to the walk, whose errors are the dispatcher's. NEW_ARCHITECTURE.md, "Shape loops".
extension JSONParser {
  @usableFromInline
  enum ShapeOutcome {
    // The container the loop was entered on has closed; `state` is what the walk's close arm
    // would have set, and `cursor`/`k` sit just after the closing bracket.
    case closed
    // Something off-pattern. `state`, `cursor` and `k` describe a position the walk understands:
    // either just after a `[`/`,` in value state, or at a separator entry in `.afterValue`.
    case fellBack
  }

  // Numeric array subtree: entered after the walk has processed a `[` (pushed, `beginArray`
  // sent) or a `,` inside an array — the second entry is what keeps an array thousands of
  // elements long in the loop across window boundaries. It runs while elements are numbers or
  // nested arrays of the same shape — Canada's
  // `[[x,y],[x,y],...]` rings and Mesh's flat vertex arrays never leave it. Per element the work
  // is one byte test on the element's first byte, one on its separator, and `emitNumber` on an
  // extent read from the index: `streamNumberRunEnd` is gone, because the separator entry *is*
  // the end. An extent `emitNumber` rejects — garbage, or whitespace before the comma — falls
  // back before anything is emitted, and the walk's scanning path re-parses it and reports
  // exactly what the dispatcher reports.
  @inlinable
  @inline(never)
  mutating func consumeNumericArray<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    count: Int,
    indices: UnsafeMutablePointer<UInt32>,
    cursor: inout Int,
    k: inout Int,
    state: inout State,
    depth: inout Int,
    containers: inout UInt64,
    into sink: inout Sink
  ) throws(JSONParsingError) -> ShapeOutcome {
    let rootDepth = depth
    var expectingValue = true
    // Entered after `[` (`.firstValue`) or, mid-array, after a `,` (`.value`): the state says
    // whether a `]` may come next.
    var first = state == .firstValue
    while k < count {
      if expectingValue {
        // The element starts at the cursor, or — if the cursor is on whitespace — at the next
        // entry, which the index guarantees is the first non-whitespace byte.
        var start = cursor
        var separatorEntry = k
        if streamIsWhitespace(base.load(fromByteOffset: start, as: UInt8.self)) {
          start = Int(indices[k])
          separatorEntry = k &+ 1
        }
        switch base.load(fromByteOffset: start, as: UInt8.self) {
        case .asciiDash, .asciiZero ... .asciiNine:
          guard separatorEntry < count else { break }
          let separator = Int(indices[separatorEntry])
          let separatorByte = base.load(fromByteOffset: separator, as: UInt8.self)
          guard separatorByte == .asciiComma || separatorByte == .asciiArrayEnd else { break }
          do {
            try self.emitNumber(base: base, from: start, to: separator, into: &sink, reportAt: separator)
          } catch {
            break
          }
          try self.checkSink(&sink, at: separator)
          cursor = separator
          k = separatorEntry
          expectingValue = false
          continue
        case .asciiArrayStart:
          guard depth < Self.maximumDepth else { break }
          // A `[` is always an entry, so it is `indices[k]` whether or not whitespace preceded it.
          sink.beginArray()
          containers &= ~(1 &<< UInt64(depth))
          depth &+= 1
          cursor = start &+ 1
          k = k &+ 1
          try self.checkSink(&sink, at: cursor)
          first = true
          continue
        case .asciiArrayEnd:
          guard first else { break }
          sink.endArray()
          depth &-= 1
          cursor = start &+ 1
          k = k &+ 1
          if depth < rootDepth {
            state = depth == 0 ? .done : .afterValue
            return .closed
          }
          try self.checkSink(&sink, at: cursor)
          expectingValue = false
          continue
        default:
          break
        }
        state = first ? .firstValue : .value
        return .fellBack
      } else {
        // After a value the next entry is the separator; whitespace before it is skipped by the
        // index's guarantee that a gap beginning with whitespace holds nothing else.
        let position = Int(indices[k])
        switch base.load(fromByteOffset: position, as: UInt8.self) {
        case .asciiComma:
          cursor = position &+ 1
          k &+= 1
          try self.checkSink(&sink, at: cursor)
          expectingValue = true
          first = false
          continue
        case .asciiArrayEnd:
          sink.endArray()
          depth &-= 1
          cursor = position &+ 1
          k &+= 1
          if depth < rootDepth {
            state = depth == 0 ? .done : .afterValue
            return .closed
          }
          try self.checkSink(&sink, at: cursor)
          continue
        default:
          state = .afterValue
          return .fellBack
        }
      }
    }
    // Out of entries: the window ends inside the subtree. Hand back at the current phase.
    state = expectingValue ? (first ? .firstValue : .value) : .afterValue
    return .fellBack
  }

  // Object members with scalar values: `"key": value,` repeated, which is most of every object
  // in the corpus. In the index a member is a fixed cadence — quote, quote, colon, then a quote
  // pair or a scalar, then comma or brace — so the four state transitions the walk spends on
  // it collapse into loads at known offsets. Entered just after `{` (state `.firstKey`) or
  // just after a `,` inside an object (state `.key`). A container value, an escaped key or
  // string, or anything malformed falls back at the member's key or at its separator; the
  // walk handles it and re-enters the loop at the next comma.
  @inlinable
  @inline(never)
  mutating func consumeObjectMembers<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    windowStart: Int,
    to n: Int,
    count: Int,
    indices: UnsafeMutablePointer<UInt32>,
    needsScan: UnsafeMutablePointer<UInt64>,
    nonASCII: UnsafeMutablePointer<UInt64>,
    cursor: inout Int,
    k: inout Int,
    state: inout State,
    depth: inout Int,
    containers: inout UInt64,
    into sink: inout Sink
  ) throws(JSONParsingError) -> ShapeOutcome {
    var first = state == .firstKey
    while true {
      // Key: three entries ahead must read quote, quote, colon, and nothing but whitespace may
      // sit between the cursor and the opening quote.
      guard k &+ 2 < count else { state = first ? .firstKey : .key; return .fellBack }
      let open = Int(indices[k])
      let close = Int(indices[k &+ 1])
      let colon = Int(indices[k &+ 2])
      guard base.load(fromByteOffset: open, as: UInt8.self) == .asciiQuote,
        base.load(fromByteOffset: close, as: UInt8.self) == .asciiQuote,
        base.load(fromByteOffset: colon, as: UInt8.self) == .asciiColon,
        open == cursor || streamIsWhitespace(base.load(fromByteOffset: cursor, as: UInt8.self))
      else { state = first ? .firstKey : .key; return .fellBack }
      var keyNonASCII = false
      if close > open &+ 1 {
        let firstBlock = (open &+ 1 &- windowStart) &>> 6
        let lastBlock = (close &- 1 &- windowStart) &>> 6
        guard !Self.windowFlag(needsScan, firstBlock: firstBlock, lastBlock: lastBlock) else {
          state = first ? .firstKey : .key
          return .fellBack
        }
        keyNonASCII = Self.windowFlag(nonASCII, firstBlock: firstBlock, lastBlock: lastBlock)
      }
      try self.emitKeyInPlace(
        base: base, from: open &+ 1, to: close, containsNonASCII: keyNonASCII, into: &sink
      )
      try self.checkSink(&sink, at: close &+ 1)
      cursor = colon &+ 1
      k &+= 3
      first = false

      // Value: at the cursor, or at the next entry when the cursor is on whitespace.
      var start = cursor
      var afterValueEntry = k
      if streamIsWhitespace(base.load(fromByteOffset: start, as: UInt8.self)) {
        guard k < count else { state = .value; return .fellBack }
        start = Int(indices[k])
        afterValueEntry = k &+ 1
      }
      switch base.load(fromByteOffset: start, as: UInt8.self) {
      case .asciiQuote:
        // A quote is always an entry: `start == indices[k]`, and the closing quote is next.
        guard k &+ 1 < count else { state = .value; return .fellBack }
        let closeQuote = Int(indices[k &+ 1])
        var valueNonASCII = false
        if closeQuote > start &+ 1 {
          let firstBlock = (start &+ 1 &- windowStart) &>> 6
          let lastBlock = (closeQuote &- 1 &- windowStart) &>> 6
          guard !Self.windowFlag(needsScan, firstBlock: firstBlock, lastBlock: lastBlock) else {
            state = .value
            return .fellBack
          }
          valueNonASCII = Self.windowFlag(nonASCII, firstBlock: firstBlock, lastBlock: lastBlock)
        }
        self.isKeyToken = false
        sink.stringBegin()
        try self.checkSink(&sink, at: start &+ 1)
        if closeQuote > start &+ 1 {
          try self.validateUTF8IfNeeded(
            base: base, from: start &+ 1, to: closeQuote, containsNonASCII: valueNonASCII,
            reportAt: nil
          )
          let slice = UnsafeBufferPointer(
            start: base.advanced(by: start &+ 1).assumingMemoryBound(to: UInt8.self),
            count: closeQuote &- start &- 1
          )
          sink.stringChunk(Span(_unsafeElements: slice))
        }
        sink.stringEnd()
        cursor = closeQuote &+ 1
        k &+= 2
        try self.checkSink(&sink, at: cursor)
      case .asciiDash, .asciiZero ... .asciiNine:
        guard afterValueEntry < count else { state = .value; return .fellBack }
        let separator = Int(indices[afterValueEntry])
        let separatorByte = base.load(fromByteOffset: separator, as: UInt8.self)
        guard separatorByte == .asciiComma || separatorByte == .asciiObjectEnd else {
          state = .value
          return .fellBack
        }
        do {
          try self.emitNumber(base: base, from: start, to: separator, into: &sink, reportAt: separator)
        } catch {
          state = .value
          return .fellBack
        }
        try self.checkSink(&sink, at: separator)
        cursor = separator
        k = afterValueEntry
      case .asciiLowerT, .asciiLowerF, .asciiLowerN:
        let byte = base.load(fromByteOffset: start, as: UInt8.self)
        let kind: UInt8 = byte == .asciiLowerT ? 0 : byte == .asciiLowerF ? 1 : 2
        let expected = Self.literalBytes[Int(kind)]
        var j = start &+ 1
        var index = 1
        while j < n && index < expected.count
          && base.load(fromByteOffset: j, as: UInt8.self) == expected[index]
        {
          index &+= 1
          j &+= 1
        }
        guard index == expected.count else { state = .value; return .fellBack }
        switch kind {
        case 0: sink.boolean(true)
        case 1: sink.boolean(false)
        default: sink.null()
        }
        cursor = j
        k = afterValueEntry
        try self.checkSink(&sink, at: cursor)
      default:
        state = .value
        return .fellBack
      }

      // Separator: the next entry, with only whitespace before it.
      guard k < count else { state = .afterValue; return .fellBack }
      let position = Int(indices[k])
      guard position == cursor || streamIsWhitespace(base.load(fromByteOffset: cursor, as: UInt8.self))
      else { state = .afterValue; return .fellBack }
      switch base.load(fromByteOffset: position, as: UInt8.self) {
      case .asciiComma:
        cursor = position &+ 1
        k &+= 1
        try self.checkSink(&sink, at: cursor)
      case .asciiObjectEnd:
        sink.endObject()
        depth &-= 1
        state = depth == 0 ? .done : .afterValue
        cursor = position &+ 1
        k &+= 1
        return .closed
      default:
        state = .afterValue
        return .fellBack
      }
    }
  }
}
