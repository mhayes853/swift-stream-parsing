import StreamParsingShims

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
  // nested arrays of the same shape — Canada's `[[x,y],[x,y],...]` rings and Mesh's flat vertex
  // arrays never leave it. Per element the work is one byte test on the element's first byte,
  // one on its separator, and a parse on an extent read from the index: `streamNumberRunEnd`
  // is gone, because the separator entry *is* the end. An extent the parse rejects — garbage,
  // or whitespace before the comma — falls back before anything is emitted, and the walk's
  // scanning path re-parses it and reports exactly what the dispatcher reports.
  //
  // Numbers are recorded like every other event; a sink sees the run as consecutive `number`
  // records in one batch and can take it in one pass (`PartialSink.events` does).
  @inlinable
  @inline(never)
  mutating func consumeNumericArray<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    to n: Int,
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
          let info: NumberInfo
          if let long = self.parseLongDecimal(base: base, from: start, to: separator, chunkEnd: n) {
            info = long
          } else {
            do {
              info = try self.parseNumber(base: base, from: start, to: separator, reportAt: separator)
            } catch {
              break
            }
          }
          try self.recordNumber(
            start: start, length: separator &- start, end: separator, info: info, into: &sink
          )
          cursor = separator
          k = separatorEntry
          expectingValue = false
          continue
        case .asciiArrayStart:
          guard depth < Self.maximumDepth else { break }
          try self.record(.beginArray, start: start, length: 1, end: start &+ 1, into: &sink)
          containers &= ~(1 &<< UInt64(depth))
          depth &+= 1
          cursor = start &+ 1
          k = k &+ 1
          first = true
          continue
        case .asciiArrayEnd:
          guard first else { break }
          try self.record(.endArray, start: start, length: 1, end: start &+ 1, into: &sink)
          depth &-= 1
          cursor = start &+ 1
          k = k &+ 1
          if depth < rootDepth {
            state = depth == 0 ? .done : .afterValue
            return .closed
          }
          expectingValue = false
          continue
        default:
          break
        }
        state = first ? .firstValue : .value
        return .fellBack
      } else {
        let position = Int(indices[k])
        switch base.load(fromByteOffset: position, as: UInt8.self) {
        case .asciiComma:
          cursor = position &+ 1
          k &+= 1
          expectingValue = true
          first = false
          continue
        case .asciiArrayEnd:
          try self.record(.endArray, start: position, length: 1, end: position &+ 1, into: &sink)
          depth &-= 1
          cursor = position &+ 1
          k &+= 1
          if depth < rootDepth {
            state = depth == 0 ? .done : .afterValue
            return .closed
          }
          continue
        default:
          state = .afterValue
          return .fellBack
        }
      }
    }
    state = expectingValue ? (first ? .firstValue : .value) : .afterValue
    return .fellBack
  }

  // `emitNumber` without the emission: the same walk, the same errors at the same offsets,
  // returning the info for the batch. Kept as its own copy rather than a refactor of
  // `emitNumber`, which is inlined into the dispatcher's `consumeNumber` and has cost 4% from
  // layout alone when its shape moved.
  // `@_transparent` rather than `@inline(__always)`: the performance inliner left this as a
  // cross-module call under the latter, generic or not, and mandatory inlining is what the
  // branchless number tail needed before it for the same reason.
  @usableFromInline
  @_transparent
  func parseNumber(
    base: UnsafeRawPointer, from: Int, to: Int, reportAt: Int
  ) throws(JSONParsingError) -> NumberInfo {
    if to &- from <= 8, to >= 8,
      base.load(fromByteOffset: from, as: UInt8.self) != .asciiZero || to &- from == 1,
      let magnitude = streamShortInteger(base: base, from: from, end: to)
    {
      return NumberInfo(
        magnitude: magnitude, exponent: 0,
        digitCount: UInt16(truncatingIfNeeded: to &- from), flags: []
      )
    }
    var flags = NumberInfo.Flags()
    var i = from
    if i < to, base.load(fromByteOffset: i, as: UInt8.self) == .asciiDash {
      flags.insert(.negative)
      i &+= 1
    }
    var magnitude: UInt64 = 0
    let integerStart = i
    i = streamAccumulateDigits(base: base, from: i, to: to, into: &magnitude)
    let integerDigits = i &- integerStart
    guard integerDigits > 0 else { throw self.error(.invalidNumber, at: reportAt) }
    if integerDigits > 1, base.load(fromByteOffset: integerStart, as: UInt8.self) == .asciiZero {
      throw self.error(.invalidNumber, at: reportAt)
    }
    var fractionDigits = 0
    if i < to, base.load(fromByteOffset: i, as: UInt8.self) == .asciiDot {
      flags.insert(.fraction)
      i &+= 1
      let fractionStart = i
      i = streamAccumulateDigits(base: base, from: i, to: to, into: &magnitude)
      fractionDigits = i &- fractionStart
      if fractionDigits == 0 { throw self.error(.invalidNumber, at: reportAt) }
    }
    var explicitExponent: Int32 = 0
    var exponentNegative = false
    if i < to, (base.load(fromByteOffset: i, as: UInt8.self) | 0x20) == .asciiLowerE {
      flags.insert(.exponent)
      i &+= 1
      if i < to {
        let sign = base.load(fromByteOffset: i, as: UInt8.self)
        if sign == .asciiDash {
          exponentNegative = true
          i &+= 1
        } else if sign == .asciiPlus {
          i &+= 1
        }
      }
      let exponentStart = i
      while i < to {
        let digit = base.load(fromByteOffset: i, as: UInt8.self) &- .asciiZero
        guard digit < 10 else { break }
        if explicitExponent < 10_000 {
          explicitExponent = explicitExponent &* 10 &+ Int32(digit)
        }
        i &+= 1
      }
      if i == exponentStart { throw self.error(.invalidNumber, at: reportAt) }
    }
    if i != to { throw self.error(.invalidNumber, at: reportAt) }
    let totalDigits = integerDigits &+ fractionDigits
    if totalDigits > 19 { flags.insert(.overflowed) }
    let signedExponent = exponentNegative ? -explicitExponent : explicitExponent
    return NumberInfo(
      magnitude: magnitude,
      exponent: Int16(clamping: Int(signedExponent) &- fractionDigits),
      digitCount: UInt16(truncatingIfNeeded: totalDigits),
      flags: flags
    )
  }

  // The third number path: a simple decimal longer than sixteen bytes, classified and
  // accumulated in one pass by the shim. Gated on length because the classification's latency
  // is only amortized by long tokens (the lab measured -27% on nine-digit integers), and on
  // the extent lying at least 32 bytes inside the chunk, which is what the shim reads. Returns
  // exactly what `parseNumber` would — the lab verified the two agree on every extent the shim
  // accepts — and nil for anything it declines.
  @inlinable
  @inline(__always)
  func parseLongDecimal(base: UnsafeRawPointer, from: Int, to: Int, chunkEnd: Int) -> NumberInfo? {
    guard to &- from > 16, from &+ 32 <= chunkEnd else { return nil }
    var magnitude: UInt64 = 0
    var exponent: Int32 = 0
    var digitCount: UInt32 = 0
    var flags: UInt32 = 0
    guard stream_parsing_decimal32(
      base.advanced(by: from).assumingMemoryBound(to: UInt8.self), to &- from,
      &magnitude, &exponent, &digitCount, &flags
    ) != 0 else { return nil }
    return NumberInfo(
      magnitude: magnitude, exponent: Int16(clamping: Int(exponent)),
      digitCount: UInt16(truncatingIfNeeded: Int(digitCount)),
      flags: NumberInfo.Flags(rawValue: UInt16(truncatingIfNeeded: flags))
    )
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
      try self.validateUTF8IfNeeded(
        base: base, from: open &+ 1, to: close, containsNonASCII: keyNonASCII, reportAt: close
      )
      try self.record(.key, start: open &+ 1, length: close &- open &- 1, end: close &+ 1, into: &sink)
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
        if closeQuote > start &+ 1 {
          do {
            try self.validateUTF8IfNeeded(
              base: base, from: start &+ 1, to: closeQuote, containsNonASCII: valueNonASCII,
              reportAt: nil
            )
          } catch {
            try self.record(.stringBegin, start: start, length: 1, end: start &+ 1, into: &sink)
            throw error
          }
        }
        try self.record(.string, start: start &+ 1, length: closeQuote &- start &- 1, end: closeQuote &+ 1, into: &sink)
        cursor = closeQuote &+ 1
        k &+= 2
      case .asciiDash, .asciiZero ... .asciiNine:
        guard afterValueEntry < count else { state = .value; return .fellBack }
        let separator = Int(indices[afterValueEntry])
        let separatorByte = base.load(fromByteOffset: separator, as: UInt8.self)
        guard separatorByte == .asciiComma || separatorByte == .asciiObjectEnd else {
          state = .value
          return .fellBack
        }
        let info: NumberInfo
        do {
          info = try self.parseNumber(base: base, from: start, to: separator, reportAt: separator)
        } catch {
          state = .value
          return .fellBack
        }
        try self.recordNumber(
          start: start, length: separator &- start, end: separator, info: info, into: &sink
        )
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
        try self.record(kind == 2 ? .null : .boolean, start: start, length: j &- start, end: j, extra: kind == 0 ? 1 : 0, into: &sink)
        cursor = j
        k = afterValueEntry
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
      case .asciiObjectEnd:
        try self.record(.endObject, start: position, length: 1, end: position &+ 1, into: &sink)
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
