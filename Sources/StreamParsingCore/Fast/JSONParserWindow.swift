import StreamParsingShims

// The windowed parse path. A chunk is walked in 32 KB windows: stage 1 (the C indexer) finds
// every position the walk must visit, then `consumeWindow` drives the sink from those
// positions with token extents already known. The dispatcher in JSONParser.swift is untouched
// and still owns two things: every token a window cuts (the walk hands the cursor back at
// the token's first byte and the dispatcher finishes it, exactly as it would at a chunk
// boundary) and every key with an escape in it. Both are cold. The design and the numbers
// that chose a 32 KB window are in NEW_ARCHITECTURE.md, "Stage-1 extraction".
//
// The contract this file has to keep is that the sink cannot tell which path ran: same
// events, same spans, same error reasons and offsets, same rejection points. That is why the
// structural arms below are the dispatcher's arms restated rather than a new grammar, and why
// every check-the-sink offset is the byte after the token, which is where the dispatcher's
// cursor sits when it reads the failure.
// The indexer, reachable by the tests that pin it against a scalar reference.
package func streamIndexWindow(
  base: UnsafeRawPointer,
  count: Int,
  baseOffset: Int,
  indices: UnsafeMutablePointer<UInt32>,
  needsScan: UnsafeMutablePointer<UInt64>,
  nonASCII: UnsafeMutablePointer<UInt64>
) -> Int {
  stream_parsing_index_window(
    base.assumingMemoryBound(to: UInt8.self), count, UInt32(baseOffset), indices, needsScan,
    nonASCII
  )
}

extension JSONParser {
  @usableFromInline static var windowByteCount: Int { 32_768 }
  // Extraction writes eight slots at a time; the last group can run seven past the true count.
  @usableFromInline static var windowIndexCapacity: Int { Self.windowByteCount &+ 8 }
  @usableFromInline static var windowBitmapWordCount: Int { Self.windowByteCount / 4096 }
  // The numeric shape loop delivers numbers in batches of up to this many; see
  // `StreamNumberBatch`. Its scratch sits after the bitmaps.
  @usableFromInline static var numberBatchCapacity: Int { 64 }
  @usableFromInline static var windowBitmapByteCount: Int { Self.windowBitmapWordCount &* 16 }
  // The walk records its events here and hands them to the sink this many at a time; a
  // number's info goes to a parallel side array, written only for number records.
  @usableFromInline static var eventBatchCapacity: Int { 256 }
  @usableFromInline static var windowScratchByteCount: Int {
    Self.windowIndexCapacity &* 4 &+ Self.windowBitmapByteCount
      &+ Self.numberBatchCapacity &* (MemoryLayout<NumberInfo>.stride &+ 8)
      &+ Self.eventBatchCapacity &* (MemoryLayout<StreamEventRecord>.stride &+ MemoryLayout<NumberInfo>.stride)
  }
  // Below this many entries per block a window is string interior with little structure, and
  // the walk has nothing to do that the dispatcher's string scan does not do faster. Census:
  // llm_message 0.7, gsoc-2018 2.1 | citm 6.0, github 6.4, twitter 7.4, canada 9.5.
  @usableFromInline static var sparseWindowDensity: Int { 3 }
  // Windows routed to the dispatcher before one is indexed again to re-measure.
  @usableFromInline static var windowProbeInterval: Int { 8 }

  @inlinable
  @inline(never)
  mutating func parseWindowed<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    count n: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    let scratch: UnsafeMutableRawPointer
    if let existing = self.windowScratch {
      scratch = existing
    } else {
      scratch = .allocate(byteCount: Self.windowScratchByteCount, alignment: 8)
      self.windowScratch = scratch
    }
    let indices = scratch.assumingMemoryBound(to: UInt32.self)
    let needsScan = (scratch + Self.windowIndexCapacity &* 4).assumingMemoryBound(to: UInt64.self)
    let nonASCII = needsScan + Self.windowBitmapWordCount
    let batchInfos = scratch
      .advanced(by: Self.windowIndexCapacity &* 4 &+ Self.windowBitmapByteCount)
      .assumingMemoryBound(to: NumberInfo.self)
    let batchTokens = UnsafeMutableRawPointer(batchInfos + Self.numberBatchCapacity)
      .assumingMemoryBound(to: UInt32.self)
    let events = UnsafeMutableRawPointer(batchTokens + Self.numberBatchCapacity &* 2)
      .assumingMemoryBound(to: StreamEventRecord.self)
    let eventInfos = UnsafeMutableRawPointer(events + Self.eventBatchCapacity)
      .assumingMemoryBound(to: NumberInfo.self)
    var eventCount = 0

    var i = 0
    if self.pendingUTF8Count > 0 {
      i = try self.completePendingUTF8(base: base, count: n, into: &sink)
    }
    var windowStart = 0
    var windowEnd = 0
    var count = 0
    var entry = 0
    while i < n {
      // A window starts only at a token boundary outside any string, which is what lets the
      // indexer run with no carried state. Anything else — mid-string, a buffered number, an
      // escape in flight — is the dispatcher's, one step at a time until it is back at one.
      guard self.state.isStructural, self.bufferCount == 0 else {
        i = try self.dispatchOnce(base: base, from: i, to: n, into: &sink)
        continue
      }
      if i >= windowEnd {
        // A sparse window is the dispatcher's, one step at a time until the cursor leaves the
        // span. The steps are bounded by where they stop, not by what they scan — a handler
        // may overrun the span, as a string longer than it would — so the sink sees exactly
        // the chunks a bulk parse produces. Every eighth window is indexed regardless, so a
        // document that turns dense again is noticed within one window.
        if self.windowDensity < Self.sparseWindowDensity,
          self.windowsSinceProbe < Self.windowProbeInterval
        {
          self.windowsSinceProbe &+= 1
          let spanEnd = Swift.min(i &+ Self.windowByteCount, n)
          while i < spanEnd {
            i = try self.dispatchOnce(base: base, from: i, to: n, into: &sink)
          }
          continue
        }
        self.windowsSinceProbe = 0
        let length = Swift.min(Self.windowByteCount, n &- i)
        count = stream_parsing_index_window(
          base.advanced(by: i).assumingMemoryBound(to: UInt8.self), length, UInt32(i),
          indices, needsScan, nonASCII
        )
        self.windowDensity = count / ((length &+ 63) &>> 6)
        windowStart = i
        windowEnd = i &+ length
        entry = 0
      } else {
        // Back inside a window the dispatcher took a token out of: the index is still the
        // truth about every position, so the walk resumes at the first entry not yet consumed.
        while entry < count && Int(indices[entry]) < i { entry &+= 1 }
      }
      do {
        i = try self.consumeWindow(
          base: base, windowStart: windowStart, windowEnd: windowEnd, to: n, from: i,
          count: count, entry: &entry,
          indices: indices, needsScan: needsScan, nonASCII: nonASCII,
          batchInfos: batchInfos, batchTokens: batchTokens,
          events: events, eventInfos: eventInfos, eventCount: &eventCount, into: &sink
        )
      } catch {
        // Events recorded before the error are delivered first: a sink rejection among them
        // is earlier in the document than the grammar error, and is what the dispatcher —
        // which reads the sink after every token — would have reported.
        try self.flushEvents(events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink)
        throw error
      }
      try self.flushEvents(events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink)
      // A cursor short of the window's end is a token the walk handed back — cut by the
      // chunk, or a key with an escape — and it is the dispatcher's, for exactly one step.
      if i < windowEnd {
        i = try self.dispatchOnce(base: base, from: i, to: n, into: &sink)
      }
    }
    self.consumedByteCount &+= n
  }

  // One iteration of the dispatcher's loop, verbatim, so the seam runs the same handlers the
  // byte fed path runs.
  @inlinable
  mutating func dispatchOnce<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to n: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var i = from
    switch self.state {
    case .value, .firstValue, .afterValue, .key, .firstKey, .afterKey, .done:
      i = try self.consumeStructuralRun(base: base, from: i, to: n, into: &sink)
    case .inString:
      i = try self.consumeStringRun(base: base, from: i, to: n, into: &sink)
    case .inKey:
      i = try self.consumeKeyRun(base: base, from: i, to: n, into: &sink)
    case .escape:
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      i &+= 1
      try self.consumeEscape(byte, at: i, into: &sink)
    case .unicode:
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      i &+= 1
      try self.consumeUnicodeDigit(byte, at: i, into: &sink)
    case .number:
      i = try self.consumeNumber(base: base, from: i, to: n, into: &sink)
    case .literal:
      i = try self.consumeLiteral(base: base, from: i, to: n, into: &sink)
    }
    try self.checkSink(&sink, at: i)
    return i
  }

  // Hands the recorded events to the sink and reads its failure once, at the offset the
  // dispatcher would have read it: the byte after the event the sink stopped at, or, for a
  // whole string, the byte after its opening quote.
  @inlinable
  mutating func flushEvents<Sink: StreamParseSink & ~Copyable>(
    _ events: UnsafeMutablePointer<StreamEventRecord>,
    _ infos: UnsafeMutablePointer<NumberInfo>,
    count: inout Int,
    base: UnsafeRawPointer,
    chunkEnd n: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    let recorded = count
    guard recorded > 0 else { return }
    count = 0
    let batch = StreamEventBatch(
      recordBase: UnsafePointer(events), infoBase: UnsafePointer(infos), count: recorded,
      bytesBase: base.assumingMemoryBound(to: UInt8.self), byteCount: n
    )
    let taken = sink.events(batch)
    if taken < recorded {
      precondition(
        sink.streamFailure != nil,
        "StreamParseSink.events returned \(taken) of \(recorded) without recording a failure."
      )
      let record = events[taken]
      try self.checkSink(&sink, at: record.kind == .string ? Int(record.start) : record.end)
    }
    try self.checkSink(&sink, at: events[recorded &- 1].end)
  }

  @inlinable
  @inline(__always)
  mutating func recordEvent<Sink: StreamParseSink & ~Copyable>(
    _ record: StreamEventRecord,
    _ events: UnsafeMutablePointer<StreamEventRecord>,
    _ infos: UnsafeMutablePointer<NumberInfo>,
    count: inout Int,
    base: UnsafeRawPointer,
    chunkEnd n: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    if count == Self.eventBatchCapacity {
      try self.flushEvents(events, infos, count: &count, base: base, chunkEnd: n, into: &sink)
    }
    events[count] = record
    count &+= 1
  }

  @inlinable
  @inline(__always)
  mutating func recordNumber<Sink: StreamParseSink & ~Copyable>(
    start: Int, end: Int, info: NumberInfo,
    _ events: UnsafeMutablePointer<StreamEventRecord>,
    _ infos: UnsafeMutablePointer<NumberInfo>,
    count: inout Int,
    base: UnsafeRawPointer,
    chunkEnd n: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    if count == Self.eventBatchCapacity {
      try self.flushEvents(events, infos, count: &count, base: base, chunkEnd: n, into: &sink)
    }
    events[count] = StreamEventRecord(kind: .number, start: start, length: end &- start)
    infos[count] = info
    count &+= 1
  }

  // Whether any block in `first...last` has its flag set. A string rarely spans more than a
  // few blocks, so this is one or two word loads.
  @inlinable
  @inline(__always)
  static func windowFlag(
    _ words: UnsafeMutablePointer<UInt64>, firstBlock: Int, lastBlock: Int
  ) -> Bool {
    var word = firstBlock &>> 6
    let lastWord = lastBlock &>> 6
    let lowMask = UInt64.max &<< UInt64(firstBlock & 63)
    let highMask = UInt64.max &>> UInt64(63 &- (lastBlock & 63))
    if word == lastWord { return words[word] & lowMask & highMask != 0 }
    if words[word] & lowMask != 0 { return true }
    word &+= 1
    while word < lastWord {
      if words[word] != 0 { return true }
      word &+= 1
    }
    return words[lastWord] & highMask != 0
  }

  // A number or literal found in the gap after an entry, in a value state. Returns the byte
  // after the token, or nil when the token reaches the chunk's end and is the dispatcher's.
  @inlinable
  @inline(__always)
  mutating func consumeGapScalar<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    at pos: Int,
    to n: Int,
    events: UnsafeMutablePointer<StreamEventRecord>,
    eventInfos: UnsafeMutablePointer<NumberInfo>,
    eventCount: inout Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int? {
    let byte = base.load(fromByteOffset: pos, as: UInt8.self)
    switch byte {
    case .asciiDash, .asciiZero ... .asciiNine:
      let end = streamNumberRunEnd(base: base, from: pos, to: n)
      guard end < n else { return nil }
      let info = try self.parseNumber(base: base, from: pos, to: end, reportAt: end)
      try self.recordNumber(
        start: pos, end: end, info: info, events, eventInfos, count: &eventCount,
        base: base, chunkEnd: n, into: &sink
      )
      return end
    case .asciiLowerT, .asciiLowerF, .asciiLowerN:
      let kind: UInt8 = byte == .asciiLowerT ? 0 : byte == .asciiLowerF ? 1 : 2
      let expected = Self.literalBytes[Int(kind)]
      var j = pos &+ 1
      var index = 1
      while j < n && index < expected.count {
        if base.load(fromByteOffset: j, as: UInt8.self) != expected[index] {
          throw self.error(.invalidLiteral, at: j)
        }
        index &+= 1
        j &+= 1
      }
      guard index == expected.count else { return nil }
      try self.recordEvent(
        StreamEventRecord(
          kind: kind == 2 ? .null : .boolean, start: pos, length: j &- pos, extra: kind == 0 ? 1 : 0
        ),
        events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink
      )
      return j
    default:
      throw self.error(.unexpectedToken, at: pos)
    }
  }

  // Returns the cursor: the window's end when everything in it was consumed, or the first
  // byte of a token handed back to the dispatcher.
  //
  // The index holds structural bytes, quotes, and scalars that follow whitespace. So a byte
  // at the cursor that is not the next entry is either whitespace — in which case everything
  // up to the next entry is whitespace, since a non-whitespace byte after whitespace would be
  // an entry — or a scalar token directly after a structural byte, which is a number or
  // literal in a value state and an error in every other, at the offset the dispatcher reports.
  // One load and one compare per entry; the walk never scans a gap.
  @inlinable
  @inline(never)
  mutating func consumeWindow<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    windowStart: Int,
    windowEnd: Int,
    to n: Int,
    from: Int,
    count: Int,
    entry: inout Int,
    indices: UnsafeMutablePointer<UInt32>,
    needsScan: UnsafeMutablePointer<UInt64>,
    nonASCII: UnsafeMutablePointer<UInt64>,
    batchInfos: UnsafeMutablePointer<NumberInfo>,
    batchTokens: UnsafeMutablePointer<UInt32>,
    events: UnsafeMutablePointer<StreamEventRecord>,
    eventInfos: UnsafeMutablePointer<NumberInfo>,
    eventCount: inout Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var state = self.state
    var depth = self.depth
    var containers = self.containers
    var k = entry
    defer {
      self.state = state
      self.depth = depth
      self.containers = containers
      entry = k
    }
    var cursor = from
    while true {
      let next = k < count ? Int(indices[k]) : windowEnd
      if cursor < next {
        let gapByte = base.load(fromByteOffset: cursor, as: UInt8.self)
        if !streamIsWhitespace(gapByte) {
          switch state {
          case .value, .firstValue:
            guard let end = try self.consumeGapScalar(
              base: base, at: cursor, to: n, events: events, eventInfos: eventInfos,
              eventCount: &eventCount, into: &sink
            ) else { return cursor }
            state = .afterValue
            cursor = end
            continue
          case .done:
            throw self.error(.trailingContent, at: cursor)
          default:
            throw self.error(.unexpectedToken, at: cursor)
          }
        }
        cursor = next
      }
      guard k < count else { return Swift.max(cursor, windowEnd) }
      let pos = next
      let byte = base.load(fromByteOffset: pos, as: UInt8.self)
      switch state {
      case .value, .firstValue:
        switch byte {
        case .asciiObjectStart:
          // The dispatcher sends `beginObject` and then rejects the depth; recorded, the event
          // precedes the error in the same order.
          try self.recordEvent(
            StreamEventRecord(kind: .beginObject, start: pos, length: 1),
            events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink
          )
          guard depth < Self.maximumDepth else { throw self.error(.depthExceeded, at: pos) }
          containers |= 1 &<< UInt64(depth)
          depth &+= 1
          state = .firstKey
          cursor = pos &+ 1
          k &+= 1
          _ = try self.consumeObjectMembers(
            base: base, windowStart: windowStart, to: n, count: count, indices: indices,
            needsScan: needsScan, nonASCII: nonASCII, cursor: &cursor, k: &k,
            state: &state, depth: &depth, containers: &containers,
            events: events, eventInfos: eventInfos, eventCount: &eventCount, into: &sink
          )
        case .asciiArrayStart:
          try self.recordEvent(
            StreamEventRecord(kind: .beginArray, start: pos, length: 1),
            events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink
          )
          guard depth < Self.maximumDepth else { throw self.error(.depthExceeded, at: pos) }
          containers &= ~(1 &<< UInt64(depth))
          depth &+= 1
          state = .firstValue
          cursor = pos &+ 1
          k &+= 1
          // A numeric array subtree is a shape loop's; it decides in two loads whether this is
          // one. It emits to the sink directly, so everything recorded so far goes first.
          if k < count {
            try self.flushEvents(events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink)
            _ = try self.consumeNumericArray(
              base: base, to: n, count: count, indices: indices,
              batchInfos: batchInfos, batchTokens: batchTokens, cursor: &cursor, k: &k,
              state: &state, depth: &depth, containers: &containers, into: &sink
            )
          }
        case .asciiArrayEnd:
          guard state == .firstValue, !Self.topIsObject(depth: depth, containers: containers)
          else { throw self.error(.unexpectedToken, at: pos) }
          try self.recordEvent(
            StreamEventRecord(kind: .endArray, start: pos, length: 1),
            events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink
          )
          depth &-= 1
          state = depth == 0 ? .done : .afterValue
          cursor = pos &+ 1
          k &+= 1
        case .asciiQuote:
          guard k &+ 1 < count else { return pos }
          let close = Int(indices[k &+ 1])
          self.isKeyToken = false
          if close > pos &+ 1 {
            let firstBlock = (pos &+ 1 &- windowStart) &>> 6
            let lastBlock = (close &- 1 &- windowStart) &>> 6
            if Self.windowFlag(needsScan, firstBlock: firstBlock, lastBlock: lastBlock) {
              // The escape path emits directly, so it runs after everything recorded so far.
              try self.flushEvents(events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink)
              sink.stringBegin()
              try self.checkSink(&sink, at: pos &+ 1)
              if let handedBack = try self.scanStringValue(
                base: base, from: pos &+ 1, to: close, into: &sink
              ) {
                state = .escape
                return handedBack
              }
              sink.stringEnd()
              try self.checkSink(&sink, at: close &+ 1)
              state = .afterValue
              cursor = close &+ 1
              k &+= 2
              continue
            }
            // One record for the whole string. The dispatcher sends `stringBegin` before it
            // scans, so a bad byte must still leave that event delivered before the error.
            do {
              try self.validateUTF8IfNeeded(
                base: base, from: pos &+ 1, to: close,
                containsNonASCII: Self.windowFlag(
                  nonASCII, firstBlock: firstBlock, lastBlock: lastBlock
                ),
                reportAt: nil
              )
            } catch {
              try self.recordEvent(
                StreamEventRecord(kind: .stringBegin, start: pos, length: 1),
                events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink
              )
              throw error
            }
          }
          try self.recordEvent(
            StreamEventRecord(kind: .string, start: pos &+ 1, length: close &- pos &- 1),
            events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink
          )
          state = .afterValue
          cursor = close &+ 1
          k &+= 2
        default:
          // A number or literal that followed whitespace, indexed so the gap before it could
          // be skipped without a scan. Anything else is the error the dispatcher reports.
          guard let end = try self.consumeGapScalar(
            base: base, at: pos, to: n, events: events, eventInfos: eventInfos,
            eventCount: &eventCount, into: &sink
          ) else { return pos }
          state = .afterValue
          cursor = end
          k &+= 1
        }

      case .afterValue:
        switch byte {
        case .asciiComma:
          guard depth > 0 else { throw self.error(.unexpectedToken, at: pos) }
          state = Self.topIsObject(depth: depth, containers: containers) ? .key : .value
          cursor = pos &+ 1
          k &+= 1
          if state == .key {
            // Back in an object after a container value: the member loop takes over again.
            _ = try self.consumeObjectMembers(
              base: base, windowStart: windowStart, to: n, count: count, indices: indices,
              needsScan: needsScan, nonASCII: nonASCII, cursor: &cursor, k: &k,
              state: &state, depth: &depth, containers: &containers,
              events: events, eventInfos: eventInfos, eventCount: &eventCount, into: &sink
            )
          } else if k < count {
            // Mid-array — after a non-numeric element, or in a new window inside an array that
            // ran on from the last one: the numeric loop resumes if the next element is a number.
            try self.flushEvents(events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink)
            _ = try self.consumeNumericArray(
              base: base, to: n, count: count, indices: indices,
              batchInfos: batchInfos, batchTokens: batchTokens, cursor: &cursor, k: &k,
              state: &state, depth: &depth, containers: &containers, into: &sink
            )
          }
        case .asciiArrayEnd:
          guard depth > 0, !Self.topIsObject(depth: depth, containers: containers) else {
            throw self.error(.unexpectedToken, at: pos)
          }
          try self.recordEvent(
            StreamEventRecord(kind: .endArray, start: pos, length: 1),
            events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink
          )
          depth &-= 1
          state = depth == 0 ? .done : .afterValue
          cursor = pos &+ 1
          k &+= 1
        case .asciiObjectEnd:
          guard Self.topIsObject(depth: depth, containers: containers) else {
            throw self.error(.unexpectedToken, at: pos)
          }
          try self.recordEvent(
            StreamEventRecord(kind: .endObject, start: pos, length: 1),
            events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink
          )
          depth &-= 1
          state = depth == 0 ? .done : .afterValue
          cursor = pos &+ 1
          k &+= 1
        default:
          throw self.error(.unexpectedToken, at: pos)
        }

      case .key, .firstKey:
        switch byte {
        case .asciiQuote:
          guard k &+ 1 < count else { return pos }
          let close = Int(indices[k &+ 1])
          var containsNonASCII = false
          if close > pos &+ 1 {
            let firstBlock = (pos &+ 1 &- windowStart) &>> 6
            let lastBlock = (close &- 1 &- windowStart) &>> 6
            // A key with an escape is buffered and decoded by the dispatcher's key path.
            if Self.windowFlag(needsScan, firstBlock: firstBlock, lastBlock: lastBlock) {
              return pos
            }
            containsNonASCII = Self.windowFlag(
              nonASCII, firstBlock: firstBlock, lastBlock: lastBlock
            )
          }
          try self.validateUTF8IfNeeded(
            base: base, from: pos &+ 1, to: close, containsNonASCII: containsNonASCII,
            reportAt: close
          )
          try self.recordEvent(
            StreamEventRecord(kind: .key, start: pos &+ 1, length: close &- pos &- 1),
            events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink
          )
          state = .afterKey
          cursor = close &+ 1
          k &+= 2
        case .asciiObjectEnd:
          guard state == .firstKey, Self.topIsObject(depth: depth, containers: containers)
          else { throw self.error(.unexpectedToken, at: pos) }
          try self.recordEvent(
            StreamEventRecord(kind: .endObject, start: pos, length: 1),
            events, eventInfos, count: &eventCount, base: base, chunkEnd: n, into: &sink
          )
          depth &-= 1
          state = depth == 0 ? .done : .afterValue
          cursor = pos &+ 1
          k &+= 1
        default:
          throw self.error(.unexpectedToken, at: pos)
        }

      case .afterKey:
        guard byte == .asciiColon else { throw self.error(.unexpectedToken, at: pos) }
        state = .value
        cursor = pos &+ 1
        k &+= 1

      case .done:
        throw self.error(.trailingContent, at: pos)

      default:
        throw self.error(.unexpectedToken, at: pos)
      }
    }
  }

  // A string value with an escape or a control byte somewhere in its blocks: the dispatcher's
  // string loop, bounded by the closing quote the indexer already found. Escapes decode in
  // place through the same fused path; one that carries a diagnostic hands the cursor back at
  // its selector with the state set to `.escape`, so the dispatcher reports it exactly where
  // and how it would have.
  @inlinable
  @inline(never)
  mutating func scanStringValue<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to close: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int? {
    var i = from
    while i < close {
      let run = streamStringRun(base: base, from: i, to: close)
      if run.end > i {
        try self.validateUTF8IfNeeded(
          base: base, from: i, to: run.end, containsNonASCII: run.containsNonASCII,
          reportAt: nil
        )
        let slice = UnsafeBufferPointer(
          start: base.advanced(by: i).assumingMemoryBound(to: UInt8.self),
          count: run.end &- i
        )
        sink.stringChunk(Span(_unsafeElements: slice))
        i = run.end
      }
      guard i < close else { break }
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      if byte == .asciiBackslash {
        if let fused = try self.fusedEscapeEnd(base: base, from: i &+ 1, to: close, into: &sink) {
          i = fused
          continue
        }
        return i &+ 1
      }
      throw self.error(.unterminatedString, at: i)
    }
    return nil
  }
}
