import StreamParsingShims

// Shape loops for the windowed walk: a run of index entries whose kinds are known ahead, processed
// with no state variable or per-token switch and extents read from the index. Speculative: every
// element is pattern-checked before any sink call or state change, and the first one off the
// pattern returns to `consumeWindow` at a well-defined position, so the loops never throw a grammar
// error themselves. NEW_ARCHITECTURE.md, "Shape loops".
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

  // Numeric array subtree, entered after a processed `[` or an array's `,` (which keeps a long array
  // in the loop across windows); Canada's rings and Mesh's vertex arrays never leave it. The
  // separator entry is the number's end. An extent the parse rejects falls back before anything is
  // emitted, and the walk re-parses it and reports exactly what the dispatcher reports.
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
            start: start, length: separator &- start, end: separator, base: base, info: info, into: &sink
          )
          cursor = separator
          k = separatorEntry
          expectingValue = false
          continue
        case .asciiArrayStart:
          guard depth < Self.maximumDepth else { break }
          try self.record(.beginArray, start: start, length: 1, end: start &+ 1, base: base, into: &sink)
          Self.pushContainer(object: false, depth: &depth, containers: &containers)
          cursor = start &+ 1
          k = k &+ 1
          first = true
          continue
        case .asciiArrayEnd:
          guard first else { break }
          try self.record(.endArray, start: start, length: 1, end: start &+ 1, base: base, into: &sink)
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
          try self.record(.endArray, start: position, length: 1, end: position &+ 1, base: base, into: &sink)
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

  // `emitNumber` without the emission: same walk, same errors at the same offsets. A copy because
  // moving `emitNumber`'s shape has cost 4% from layout alone. LOCKSTEP: `emitNumber` and
  // `emitGeneralNumber`, untested against each other; `to >= 8` bounds `streamShortInteger`'s
  // backward load in both. `@_transparent`: `@inline(__always)` left a cross-module call.
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

  // The third number path: a simple decimal over sixteen bytes, classified and accumulated in one
  // pass by the shim; agrees with `parseNumber` on every extent it accepts, nil otherwise. Gated on
  // length (only long tokens amortize its latency; nine digits measured -27%) and on 32 bytes of
  // chunk from `from`, which the shim reads.
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

  // Object members with scalar values: in the index a member is a fixed cadence (quote, quote,
  // colon, a quote pair or a scalar, comma or brace), so the walk's four transitions become loads
  // at known offsets. Entered after `{` (`.firstKey`) or an object's `,` (`.key`). A container, an
  // escape or anything malformed falls back at the key or separator; the walk re-enters at a comma.
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
      // A scalar directly after a quote has no index entry, so the key-to-colon gap is checked
      // before the key is emitted; compact JSON takes the adjacent-colon compare without a scan.
      guard colon == close &+ 1
        || streamWhitespaceEnd(base: base, from: close &+ 1, to: colon) == colon
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
      try self.record(.key, start: open &+ 1, length: close &- open &- 1, end: close &+ 1, base: base, into: &sink)
      cursor = colon &+ 1
      k &+= 3
      first = false

      // Value: at the cursor, or at the next entry when the cursor is on whitespace.
      var start = cursor
      var afterValueEntry = k
      // A complete key/colon can be the last bytes of an incomplete chunk. Leave the
      // value pending before inspecting its first byte; it belongs to the next parse call.
      guard start < n else { state = .value; return .fellBack }
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
            try self.record(.stringBegin, start: start, length: 1, end: start &+ 1, base: base, into: &sink)
            throw error
          }
        }
        try self.record(.string, start: start &+ 1, length: closeQuote &- start &- 1, end: closeQuote &+ 1, base: base, into: &sink)
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
          start: start, length: separator &- start, end: separator, base: base, info: info, into: &sink
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
        try self.record(kind == 2 ? .null : .boolean, start: start, length: j &- start, end: j, extra: kind == 0 ? 1 : 0, base: base, into: &sink)
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
        try self.record(.endObject, start: position, length: 1, end: position &+ 1, base: base, into: &sink)
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
