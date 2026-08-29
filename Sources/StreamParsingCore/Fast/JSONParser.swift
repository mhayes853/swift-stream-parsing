// MARK: - Error

public struct JSONParsingError: Error, Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    case unexpectedToken
    case invalidNumber
    case invalidLiteral
    case invalidEscape
    case invalidUTF8
    case unterminatedString
    case unterminatedContainer
    case trailingContent
    case depthExceeded
    case bufferExhausted
    case sinkRejectedToken(StreamSinkFailure)
  }

  public var reason: Reason
  public var byteOffset: Int

  public init(reason: Reason, byteOffset: Int) {
    self.reason = reason
    self.byteOffset = byteOffset
  }
}

// MARK: - JSONParser

public struct JSONParser: ~Copyable {
  // The structural states are declared first, and `done` is grouped with them rather than left at
  // the end, so "is this still a structural state" is one unsigned compare. `consumeStructuralRun`
  // asks it once per byte, which is the only reason the order matters; nothing depends on the
  // numeric values otherwise.
  @usableFromInline
  enum State: UInt8 {
    case value, firstValue, afterValue, key, firstKey, afterKey, done
    case inString, inKey, escape, unicode, number, literal

    @inlinable
    var isStructural: Bool { self.rawValue <= State.done.rawValue }
  }

  // 1 = object, 0 = array. Depth beyond `maximumDepth` is rejected rather than spilled, which
  // keeps container tracking to a single register.
  @usableFromInline static let maximumDepth = 64

  @usableFromInline var state = State.value
  @usableFromInline var containers: UInt64 = 0
  @usableFromInline var depth = 0

  @usableFromInline var buffer: UnsafeMutableBufferPointer<UInt8>
  @usableFromInline var bufferCount = 0
  @usableFromInline var ownsBuffer: Bool

  @usableFromInline var unicodeValue: UInt32 = 0
  @usableFromInline var unicodeRemaining = 0
  @usableFromInline var highSurrogate: UInt32 = 0

  // Whether the string token being read is a key. The escape and unicode states are shared
  // between keys and string values, so this has to be remembered rather than derived:
  // `bufferCount > 0` cannot stand in for it, because a key whose first character is an escape
  // has buffered nothing yet, and misrouting it emitted the decoded byte as string content.
  @usableFromInline var isKeyToken = false
  @usableFromInline var keyContainsNonASCII = false

  @usableFromInline var literalKind: UInt8 = 0
  @usableFromInline var literalIndex = 0

  @usableFromInline var pendingUTF8Count = 0
  @usableFromInline var consumedByteCount = 0

  public init(bufferCapacity: Int = 4096) {
    self.buffer = .allocate(capacity: Swift.max(bufferCapacity, 64))
    self.ownsBuffer = true
  }

  public init(buffer: UnsafeMutableBufferPointer<UInt8>) {
    precondition(
      buffer.count >= Self.reservedTailByteCount,
      "JSONParser requires a caller-supplied buffer of at least \(Self.reservedTailByteCount) bytes."
    )
    self.buffer = buffer
    self.ownsBuffer = false
  }

  deinit {
    if self.ownsBuffer { self.buffer.deallocate() }
  }

  public var byteOffset: Int { self.consumedByteCount }

  // MARK: Entry points

  @inlinable
  public mutating func parse<Sink: StreamParseSink & ~Copyable>(
    _ input: Span<UInt8>,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    try input.withUnsafeBufferPointer { buffer throws(JSONParsingError) in
      try self.parse(buffer, into: &sink)
    }
  }

  @inlinable
  public mutating func parse<Sink: StreamParseSink & ~Copyable>(
    byte: UInt8,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    var scalar = byte
    try withUnsafePointer(to: &scalar) { pointer throws(JSONParsingError) in
      try self.parse(UnsafeBufferPointer(start: pointer, count: 1), into: &sink)
    }
  }

  @inlinable
  public mutating func parse<Sink: StreamParseSink & ~Copyable>(
    _ input: UnsafeBufferPointer<UInt8>,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    guard let start = input.baseAddress, !input.isEmpty else { return }
    let base = UnsafeRawPointer(start)
    let n = input.count
    var i = 0

    if self.pendingUTF8Count > 0 {
      i = try self.completePendingUTF8(base: base, count: n, into: &sink)
    }

    while i < n {
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
    }

    self.consumedByteCount &+= n
  }

  @inlinable
  public mutating func finish<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink
  ) throws(JSONParsingError) {
    switch self.state {
    case .number:
      try self.emitBufferedNumber(into: &sink, reportAt: 0)
      self.state = .done
    case .value, .firstValue, .key, .firstKey, .afterKey:
      throw self.error(.unexpectedToken, at: 0)
    case .inString, .inKey, .escape, .unicode:
      throw self.error(.unterminatedString, at: 0)
    case .literal:
      throw self.error(.invalidLiteral, at: 0)
    case .afterValue, .done:
      break
    }
    if self.depth > 0 { throw self.error(.unterminatedContainer, at: 0) }
    if self.pendingUTF8Count > 0 { throw self.error(.invalidUTF8, at: 0) }
    try self.checkSink(&sink, at: 0)
  }

  // MARK: Structural

  // Structural bytes arrive in runs — `},{"`, `":`, `,"`, `[[` — and `parse` is a dispatcher that
  // calls out once per token, so each byte of such a run used to cost a call, a return and a
  // re-entry into the dispatch switch. Measured on the release build, `parse` is 1284 bytes with
  // the handlers all out of line, so that round trip, not the byte's own work, is what a
  // structural byte costs. The loop stays here while the state stays structural, which turns a run
  // into one call.
  //
  // `checkSink` still runs per byte rather than per run: a sink that rejects a token has to stop
  // the parse at the token it rejected, and where that surfaces is what `ErrorOffsetTests` pins.
  // `fuseAfterValue` carries the other half of that guarantee, since it can move the cursor
  // between a rejection and the check that reads it.
  // Out of line by force, with `consumeStructural` folded into it by force: left alone the
  // optimizer did exactly the inverse — it inlined this loop into `parse`, growing the dispatcher
  // from 1284 to 1424 bytes, and still called `consumeStructural` once per byte, which is the call
  // this exists to delete. `parse` stays a thin dispatcher and the run owns its own registers.
  //
  // The three fields the step reads and writes on every byte — `state`, `depth`, `containers` —
  // are copied into locals for the run and written back on every exit, the throwing ones
  // included. Left as fields they lived in memory: the release build stored `state` at the end
  // of one byte and loaded it back at the start of the next, and that store-to-load round trip,
  // not the switch, was the loop-carried dependency. A structural byte's work is a handful of
  // compares on a register; it should not wait on a store buffer to deliver the previous byte's
  // result.
  @inlinable
  @inline(never)
  mutating func consumeStructuralRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var i = from
    var state = self.state
    var depth = self.depth
    var containers = self.containers
    defer {
      self.state = state
      self.depth = depth
      self.containers = containers
    }
    while i < to {
      // The scan hands back the byte it stopped on rather than just the index, so the dispatch
      // below reads a register instead of loading the same address the scan's one-compare fast
      // path just tested. Two L1 accesses per structural byte became one.
      let scanned = streamWhitespaceEndByte(base: base, from: i, to: to)
      i = scanned.end
      if i == to { break }
      let byte = scanned.byte
      i &+= 1
      // A number is the one token whose first byte belongs to the token itself, so the run ends
      // and the byte is handed back for `.number` to re-read.
      if try self.consumeStructural(
        byte, base: base, cursor: &i, to: to, state: &state, depth: &depth,
        containers: &containers, into: &sink
      ) {
        i &-= 1
        break
      }
      try self.checkSink(&sink, at: i)
      if !state.isStructural { break }
    }
    return i
  }

  @inlinable
  @inline(__always)
  mutating func consumeStructural<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8,
    base: UnsafeRawPointer,
    cursor: inout Int,
    to: Int,
    state: inout State,
    depth: inout Int,
    containers: inout UInt64,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Bool {
    let at = cursor &- 1
    switch state {
    case .value, .firstValue:
      switch byte {
      case .asciiObjectStart:
        sink.beginObject()
        guard depth < Self.maximumDepth else { throw self.error(.depthExceeded, at: at) }
        containers |= 1 &<< Self.shiftAmount(depth)
        depth &+= 1
        state = .firstKey
      case .asciiArrayStart:
        sink.beginArray()
        guard depth < Self.maximumDepth else { throw self.error(.depthExceeded, at: at) }
        containers &= ~(1 &<< Self.shiftAmount(depth))
        depth &+= 1
        state = .firstValue
      case .asciiArrayEnd:
        guard state == .firstValue, !Self.topIsObject(depth: depth, containers: containers) else {
          throw self.error(.unexpectedToken, at: at)
        }
        sink.endArray()
        depth &-= 1
        state = depth == 0 ? .done : .afterValue
      case .asciiQuote:
        self.isKeyToken = false
        sink.stringBegin()
        state = .inString
      case .asciiLowerT:
        self.startLiteral(kind: 0)
        state = .literal
      case .asciiLowerF:
        self.startLiteral(kind: 1)
        state = .literal
      case .asciiLowerN:
        self.startLiteral(kind: 2)
        state = .literal
      case .asciiDash, .asciiZero ... .asciiNine:
        self.resetNumber()
        state = .number
        return true
      default:
        throw self.error(.unexpectedToken, at: at)
      }

    case .afterValue:
      switch byte {
      case .asciiComma:
        guard depth > 0 else { throw self.error(.unexpectedToken, at: at) }
        state = Self.topIsObject(depth: depth, containers: containers) ? .key : .value
      case .asciiArrayEnd:
        guard depth > 0, !Self.topIsObject(depth: depth, containers: containers) else {
          throw self.error(.unexpectedToken, at: at)
        }
        sink.endArray()
        depth &-= 1
        state = depth == 0 ? .done : .afterValue
      case .asciiObjectEnd:
        guard Self.topIsObject(depth: depth, containers: containers) else {
          throw self.error(.unexpectedToken, at: at)
        }
        sink.endObject()
        depth &-= 1
        state = depth == 0 ? .done : .afterValue
      default:
        throw self.error(.unexpectedToken, at: at)
      }

    case .key, .firstKey:
      switch byte {
      case .asciiQuote:
        // A key is read here, in place, whenever its closing quote is in this chunk — the
        // scan is the string scanner's, and the emission is a borrow into the input. Only a key
        // the chunk cuts goes to `consumeKeyRun` to be buffered. Reading it here rather than
        // there is what keeps the string loop's registers for string content, and it also
        // means the run carries straight on through the colon into the value's first byte, so
        // `"key": value` costs this call and no other.
        let run = streamStringRun(base: base, from: cursor, to: to)
        if run.end < to, base.load(fromByteOffset: run.end, as: UInt8.self) == .asciiQuote {
          try self.emitKeyInPlace(
            base: base, from: cursor, to: run.end, containsNonASCII: run.containsNonASCII,
            into: &sink
          )
          cursor = run.end &+ 1
          state = .afterKey
          return false
        }
        self.isKeyToken = true
        self.bufferCount = 0
        self.keyContainsNonASCII = false
        state = .inKey
      case .asciiObjectEnd:
        guard state == .firstKey, Self.topIsObject(depth: depth, containers: containers) else {
          throw self.error(.unexpectedToken, at: at)
        }
        sink.endObject()
        depth &-= 1
        state = depth == 0 ? .done : .afterValue
      default:
        throw self.error(.unexpectedToken, at: at)
      }

    case .afterKey:
      guard byte == .asciiColon else { throw self.error(.unexpectedToken, at: at) }
      state = .value

    case .done:
      throw self.error(.trailingContent, at: at)

    default:
      throw self.error(.unexpectedToken, at: at)
    }
    return false
  }


  // A value inside a container is followed by `,` and then the next value's first byte. Measured
  // across the corpus there is never whitespace before the comma (166,449 of them, 100%) and 7-25
  // bytes of it after, so this is a compare, the existing SIMD whitespace scan, and a dispatch on
  // one byte.
  //
  // The point is not those bytes, it is that consuming *all* of them leaves nothing structural
  // before the next value's content, so the `consumeStructuralRun` call for this member
  // disappears entirely. That is the test a fusion has to pass to be worth anything here: fusing
  // the colon after a key looked identical on paper and bought nothing, because the value's
  // opening quote still followed it and the run had to happen anyway.
  //
  // Arrays are handled as well as objects, and not for symmetry: with only the object case, every
  // comma in `canada` — 111,129 of them, all inside arrays of numbers — paid the test and got
  // nothing, and it measured -3.8%.
  //
  // Inlined into the two value-end sites deliberately. Both are already out of line, so the
  // duplication lands in `consumeStringRun` and `consumeNumber` rather than in `parse`.
  //
  // A sink that has already failed stops the fusion, which is a correctness requirement rather
  // than an optimisation. `parse` reads the sink's failure once per token with the cursor as the
  // offset, so a fusion that ran first moved that cursor past the comma and onto the *next*
  // token before the rejection surfaced: `[1,2]` with a sink refusing numbers reported byte 3,
  // the `2`, for a rejection of the `1`. It also delivered the next token's `stringBegin` to a
  // sink that had already failed. Bailing here leaves the cursor at the token end, which is the
  // offset the unfused path reports, so where a rejection surfaces no longer depends on whether
  // the bytes after it happened to be fusable.
  //
  // The test is third, after the two register compares, and it reads the same field `checkSink`
  // reads a few instructions later, so it is a load that was going to happen anyway.
  @inlinable
  @inline(__always)
  mutating func fuseAfterValue<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, into sink: inout Sink
  ) -> Int {
    guard self.depth > 0, from < to,
      base.load(fromByteOffset: from, as: UInt8.self) == .asciiComma,
      sink.streamFailure == nil
    else {
      return from
    }
    let next = streamWhitespaceEnd(base: base, from: from &+ 1, to: to)
    guard next < to else { return from }
    let byte = base.load(fromByteOffset: next, as: UInt8.self)

    if self.topIsObject {
      // The quote is left for the structural run, which reads the key in place and carries on
      // through the colon; entering `.inKey` here would send the key through the buffered path.
      guard byte == .asciiQuote else { return from }
      self.state = .key
      return next
    }

    switch byte {
    case .asciiQuote:
      self.isKeyToken = false
      sink.stringBegin()
      self.state = .inString
      return next &+ 1
    case .asciiDash, .asciiZero ... .asciiNine:
      // The first byte of a number belongs to the number, so it is left for `.number` to re-read.
      self.resetNumber()
      self.state = .number
      return next
    default:
      return from
    }
  }

  // The colon after a key, fused together with the value's first byte. The colon alone was
  // measured and rejected earlier in this file's history: it moved one byte into the key's call
  // and the structural run still had to happen for the quote that always follows it. Consuming
  // the value's opening byte as well is what passes the test that fusion set — nothing
  // structural is left before the next token — so for `"key": "value"` and `"key": 42`, which
  // is most of every object in the corpus, the structural run does not run at all. Whitespace
  // between them is the one space every pretty printer emits, scanned the same way
  // `fuseAfterValue` scans its run.
  //
  // Containers and literals after the colon are left to the structural run: `{` and `[` push a
  // frame and `t`/`f`/`n` start a literal, and spelling those here would grow `consumeStringRun`
  // for arms the profile says are a small share of keys. Same guard order as `fuseAfterValue`,
  // and for the same reason: a sink that rejected the key must stop the fusion so the rejection
  // surfaces where the unfused path reports it.

  // MARK: Strings

  // String values only. A key comes through here never: one read whole goes through the
  // structural run in place, and one the chunk cut goes through `consumeKeyRun` below. Keeping
  // the key's buffer bookkeeping out of this loop is deliberate — this is the byte fed path's
  // per-byte call, and its register allocation sits on an edge where a live value more is a
  // spill on every call.
  @inlinable
  mutating func consumeStringRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var i = from
    while true {
      let run = streamStringRun(base: base, from: i, to: to)
      let end = run.end

      if end > i {
        if self.highSurrogate != 0 { throw self.loneHighSurrogateError(reportAt: i) }
        let emitEnd = end == to ? try self.trimmingIncompleteUTF8(base: base, from: i, to: end) : end
        if emitEnd > i {
          try self.validateUTF8IfNeeded(
            base: base,
            from: i,
            to: emitEnd,
            containsNonASCII: run.containsNonASCII,
            reportAt: nil
          )
          let slice = UnsafeBufferPointer(
            start: base.advanced(by: i).assumingMemoryBound(to: UInt8.self),
            count: emitEnd &- i
          )
          sink.stringChunk(Span(_unsafeElements: slice))
        }
        if emitEnd < end {
          try self.holdPendingUTF8(base: base, from: emitEnd, to: end)
        }
        i = end
      }

      guard i < to else { return i }

      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      let byteAt = i
      i &+= 1
      if byte == .asciiQuote {
        if self.highSurrogate != 0 { throw self.loneHighSurrogateError(reportAt: byteAt) }
        sink.stringEnd()
        self.state = .afterValue
        return self.fuseAfterValue(base: base, from: i, to: to, into: &sink)
      } else if byte == .asciiBackslash {
        // Decoding the escape here keeps the scan going; the states exist for the escape that
        // straddles a chunk boundary and for the ones carrying diagnostics.
        if let fused = try self.fusedEscapeEnd(base: base, from: i, to: to, into: &sink) {
          i = fused
          continue
        }
        self.state = .escape
        return i
      } else {
        throw self.error(.unterminatedString, at: byteAt)
      }
    }
  }

  // A key the structural run could not read in place — its closing quote was past the chunk,
  // or an escape has to decode into it — buffered for contiguity and emitted whole at its
  // closing quote. Byte fed input sends every key here; bulk input sends almost none.
  @inlinable
  @inline(never)
  mutating func consumeKeyRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var i = from
    while true {
      let run = streamStringRun(base: base, from: i, to: to)
      let end = run.end

      if end > i {
        if self.highSurrogate != 0 { throw self.loneHighSurrogateError(reportAt: i) }
        self.keyContainsNonASCII = self.keyContainsNonASCII || run.containsNonASCII
        try self.appendToBuffer(base: base, from: i, count: end &- i, reportAt: i)
        i = end
      }

      guard i < to else { return i }

      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      let byteAt = i
      i &+= 1
      if byte == .asciiQuote {
        if self.highSurrogate != 0 { throw self.loneHighSurrogateError(reportAt: byteAt) }
        try self.emitBufferedKey(into: &sink, reportAt: byteAt)
        self.state = .afterKey
        return i
      } else if byte == .asciiBackslash {
        if let fused = try self.fusedEscapeEnd(base: base, from: i, to: to, into: &sink) {
          i = fused
          continue
        }
        self.state = .escape
        return i
      } else {
        throw self.error(.unterminatedString, at: byteAt)
      }
    }
  }

  // The escape states are per byte: `\n` costs the dispatcher two iterations, `\uXXXX` five and a
  // surrogate pair eleven, all to produce at most four bytes of content. When the whole escape is
  // present in the chunk, decoding it here and returning its end lets `consumeStringRun` keep
  // scanning without ever handing control back.
  //
  // Only escapes with no diagnostics attached are fused. A bad hex digit, a lone surrogate, an
  // unrecognised escape character, a pending high surrogate, or an escape running past the end of
  // the chunk all return nil and fall back to the per byte states. That is what keeps error offsets
  // and resumption identical: this path never reports anything, so it cannot report it in the
  // wrong place, and it commits nothing before it knows it can finish.
  @inlinable
  @inline(__always)
  mutating func fusedEscapeEnd<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, into sink: inout Sink
  ) throws(JSONParsingError) -> Int? {
    guard self.highSurrogate == 0, from < to else { return nil }
    let selector = base.load(fromByteOffset: from, as: UInt8.self)
    guard selector != .asciiLowerU else {
      return try self.fusedUnicodeEscapeEnd(base: base, from: from, to: to, into: &sink)
    }
    guard let decoded = streamDecodeSimpleEscape(selector) else { return nil }
    try self.emitDecoded(byte: decoded, into: &sink, reportAt: from)
    return from &+ 1
  }

  // Out of line, and for the same reason the whitespace vector body is: this is inlined into
  // `consumeStringRun`, and the hex decode plus the surrogate pair handling is dead weight in it
  // for any document whose escapes are all one character. Spelling it inline alongside the simple
  // escapes above cost `Fast Escaped string` — `a\nb\t` repeated, no `\u` in it at all — 18.5%,
  // and every string heavy document 1-5%, while the documents it exists for kept their gain either
  // way. A `\u` escape is five bytes of work and saves five dispatcher iterations, so it can
  // afford the call; `\n` is one byte and cannot.
  @inlinable
  @inline(never)
  mutating func fusedUnicodeEscapeEnd<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, into sink: inout Sink
  ) throws(JSONParsingError) -> Int? {
    guard from &+ 5 <= to, let scalar = streamHexQuad(base: base, from: from &+ 1) else {
      return nil
    }
    var value = scalar
    var end = from &+ 5

    if scalar >= .highSurrogateFloor, scalar <= .highSurrogateCeiling {
      // A pair is twelve bytes and has to be complete and well formed to be fused; a high
      // surrogate followed by anything else is a diagnostic, so it goes to the per byte path.
      // The bounds test is first, so the halfword load below stays inside the chunk.
      guard end &+ 6 <= to,
        UInt16(littleEndian: base.loadUnaligned(fromByteOffset: end, as: UInt16.self))
          == streamUnicodeEscapePrefix,
        let low = streamHexQuad(base: base, from: end &+ 2),
        low >= .lowSurrogateFloor, low <= .lowSurrogateCeiling
      else {
        return nil
      }
      value =
        .utf8ThreeByteCeiling &+ ((scalar &- .highSurrogateFloor) << 10)
        &+ (low &- .lowSurrogateFloor)
      end &+= 6
    } else if scalar >= .lowSurrogateFloor, scalar <= .lowSurrogateCeiling {
      // A lone low surrogate is a diagnostic, so it goes to the per-byte path.
      return nil
    }

    try self.emitScalar(value, into: &sink, reportAt: from)
    return end
  }

  @inlinable
  mutating func consumeEscape<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8,
    at offset: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    if byte == .asciiLowerU {
      self.unicodeValue = 0
      self.unicodeRemaining = 4
      self.state = .unicode
      return
    }
    // A high surrogate must be followed immediately by a low surrogate escape. Any other escape
    // severs the pair, and severing it first is also what keeps the content in order around it.
    if self.highSurrogate != 0 {
      throw self.loneHighSurrogateError(reportAt: offset &- 1)
    }
    guard let decoded = streamDecodeSimpleEscape(byte) else {
      throw self.error(.invalidEscape, at: offset &- 1)
    }
    try self.emitDecoded(byte: decoded, into: &sink, reportAt: offset &- 1)
    self.state = self.stateAfterEscape
  }

  @inlinable
  mutating func consumeUnicodeDigit<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8,
    at offset: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    guard let value = Self.hexValue(byte) else { throw self.error(.invalidEscape, at: offset &- 1) }
    self.unicodeValue = (self.unicodeValue << 4) | value
    self.unicodeRemaining &-= 1
    guard self.unicodeRemaining == 0 else { return }

    let scalar = self.unicodeValue
    if scalar >= .highSurrogateFloor, scalar <= .highSurrogateCeiling {
      // A second high surrogate would silently replace the pending one, leaving the first lone.
      if self.highSurrogate != 0 {
        throw self.loneHighSurrogateError(reportAt: offset &- 1)
      }
      self.highSurrogate = scalar
      self.state = self.stateAfterEscape
      return
    }
    if scalar >= .lowSurrogateFloor, scalar <= .lowSurrogateCeiling, self.highSurrogate == 0 {
      throw self.error(.invalidEscape, at: offset &- 1)
    }
    if scalar >= .lowSurrogateFloor, scalar <= .lowSurrogateCeiling, self.highSurrogate != 0 {
      let combined =
        .utf8ThreeByteCeiling &+ ((self.highSurrogate &- .highSurrogateFloor) << 10)
        &+ (scalar &- .lowSurrogateFloor)
      self.highSurrogate = 0
      try self.emitScalar(combined, into: &sink, reportAt: offset &- 1)
    } else {
      // A pending high surrogate followed by any scalar but a low surrogate is lone.
      if self.highSurrogate != 0 {
        throw self.loneHighSurrogateError(reportAt: offset &- 1)
      }
      try self.emitScalar(scalar, into: &sink, reportAt: offset &- 1)
    }
    self.state = self.stateAfterEscape
  }

  // A high surrogate with no low surrogate after it. Every event that can follow one asks for
  // this, and it is out of line and returns the error rather than throwing it so that the common
  // path at each call site stays a compare against zero: two of the four callers are in
  // `consumeStringRun`, once per literal run and once per closing quote.
  @inlinable
  @inline(never)
  func loneHighSurrogateError(reportAt: Int) -> JSONParsingError {
    self.error(.invalidEscape, at: reportAt)
  }

  @inlinable
  var stateAfterEscape: State {
    self.isKeyToken ? .inKey : .inString
  }

  // MARK: Numbers

  @inlinable
  mutating func resetNumber() {
    self.bufferCount = 0
  }

  // The scan is greedy over the number byte class and the parse is one structured walk over
  // the whole token at its end — sign, integer digits, fraction, exponent — so the per-byte
  // state machine is gone and a number is reported exactly once, complete. The strategy table
  // is in NEW_ARCHITECTURE.md: deferring the parse beat the fused per-byte accumulation on
  // every corpus measured, and 8-digit blocks are 2.2x on 17-19 digit ids.
  @inlinable
  mutating func consumeNumber<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    let end = streamNumberRunEnd(base: base, from: from, to: to)
    if end == to {
      // The token may continue in the next chunk, so its bytes are carried whole; a document
      // that ends inside a number is settled by finish().
      try self.appendToBuffer(base: base, from: from, count: end &- from, reportAt: end)
      return end
    }
    if self.bufferCount == 0 {
      try self.emitNumber(base: base, from: from, to: end, into: &sink, reportAt: end)
    } else {
      try self.appendToBuffer(base: base, from: from, count: end &- from, reportAt: end)
      try self.emitBufferedNumber(into: &sink, reportAt: end)
    }
    self.state = .afterValue
    return self.fuseAfterValue(base: base, from: end, to: to, into: &sink)
  }

  @inlinable
  mutating func emitBufferedNumber<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    let count = self.bufferCount
    try self.emitNumber(
      base: UnsafeRawPointer(self.buffer.baseAddress!), from: 0, to: count, into: &sink,
      reportAt: reportAt
    )
    self.bufferCount = 0
  }

  // Parses and validates in the same walk: the grammar is the segment order itself, so a byte
  // the grammar has no place for fails the final position check rather than a tracked flag.
  // That is also what rejects doubled exponent signs, which the per-byte rules accepted.
  @inlinable
  mutating func emitNumber<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink,
    reportAt: Int
  ) throws(JSONParsingError) {
    // The shape four of the seven corpus payloads are mostly made of: an unsigned integer of one
    // to eight digits, no sign, no dot, no exponent. The kernel's digit test doubles as the shape
    // test, so this replaces the sign, leading zero, dot, exponent and final position checks
    // below rather than adding to them. Anything it declines falls through unchanged.
    if to &- from <= 8, to >= 8,
      base.load(fromByteOffset: from, as: UInt8.self) != .asciiZero || to &- from == 1,
      let magnitude = streamShortInteger(base: base, from: from, end: to)
    {
      let slice = UnsafeBufferPointer(
        start: base.advanced(by: from).assumingMemoryBound(to: UInt8.self),
        count: to &- from
      )
      sink.number(
        Span(_unsafeElements: slice),
        info: NumberInfo(
          magnitude: magnitude,
          exponent: 0,
          digitCount: UInt16(truncatingIfNeeded: to &- from),
          flags: []
        )
      )
      return
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
    do {
      guard integerDigits > 0 else { throw self.error(.invalidNumber, at: reportAt) }
      if integerDigits > 1, base.load(fromByteOffset: integerStart, as: UInt8.self) == .asciiZero {
        throw self.error(.invalidNumber, at: reportAt)
      }
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
    let info = NumberInfo(
      magnitude: magnitude,
      exponent: Int16(clamping: Int(signedExponent) &- fractionDigits),
      digitCount: UInt16(truncatingIfNeeded: totalDigits),
      flags: flags
    )
    let slice = UnsafeBufferPointer(
      start: base.advanced(by: from).assumingMemoryBound(to: UInt8.self),
      count: to &- from
    )
    sink.number(Span(_unsafeElements: slice), info: info)
  }

  // MARK: Literals

  @usableFromInline
  static let literalBytes: [[UInt8]] = [
    [.asciiLowerT, .asciiLowerR, .asciiLowerU, .asciiLowerE],
    [.asciiLowerF, .asciiLowerA, .asciiLowerL, .asciiLowerS, .asciiLowerE],
    [.asciiLowerN, .asciiLowerU, .asciiLowerL, .asciiLowerL],
  ]

  @inlinable
  mutating func startLiteral(kind: UInt8) {
    self.literalKind = kind
    self.literalIndex = 1
  }

  @inlinable
  mutating func consumeLiteral<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    let expected = Self.literalBytes[Int(self.literalKind)]
    var i = from
    while i < to && self.literalIndex < expected.count {
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      if byte != expected[self.literalIndex] {
        throw self.error(.invalidLiteral, at: i)
      }
      self.literalIndex &+= 1
      i &+= 1
    }
    if self.literalIndex == expected.count {
      switch self.literalKind {
      case 0: sink.boolean(true)
      case 1: sink.boolean(false)
      default: sink.null()
      }
      self.state = .afterValue
    }
    return i
  }

  // MARK: Buffer

  @inlinable
  mutating func appendToBuffer(
    base: UnsafeRawPointer, from: Int, count: Int, reportAt: Int
  ) throws(JSONParsingError) {
    guard count > 0 else { return }
    guard self.bufferCount &+ count &+ Self.reservedTailByteCount <= self.buffer.count else {
      throw self.error(.bufferExhausted, at: reportAt)
    }
    UnsafeMutableRawPointer(self.buffer.baseAddress! + self.bufferCount)
      .copyMemory(from: base.advanced(by: from), byteCount: count)
    self.bufferCount &+= count
  }

  // A key read whole out of the input: validated in place and handed to the sink as a borrow,
  // with the document's own bytes behind it. No copy, no capacity check, no padding — every
  // reader in the tree (`paddedWord`, the dictionary's hash and equality) reads within the span's
  // count, which is the only contract a borrowed span can offer. The caller owns the state.
  @inlinable
  @inline(__always)
  mutating func emitKeyInPlace<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, containsNonASCII: Bool, into sink: inout Sink
  ) throws(JSONParsingError) {
    try self.validateUTF8IfNeeded(
      base: base, from: from, to: to, containsNonASCII: containsNonASCII, reportAt: to
    )
    let slice = UnsafeBufferPointer(
      start: base.advanced(by: from).assumingMemoryBound(to: UInt8.self), count: to &- from
    )
    sink.key(Span(_unsafeElements: slice))
  }

  @inlinable
  mutating func emitBufferedKey<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    let count = self.bufferCount
    let base = UnsafeRawPointer(self.buffer.baseAddress!)
    try self.validateUTF8IfNeeded(
      base: base,
      from: 0,
      to: count,
      containsNonASCII: self.keyContainsNonASCII,
      reportAt: reportAt
    )
    let slice = UnsafeBufferPointer(start: self.buffer.baseAddress!, count: count)
    sink.key(Span(_unsafeElements: slice))
    self.bufferCount = 0
    self.keyContainsNonASCII = false
  }

  // MARK: UTF-8

  @inlinable
  mutating func trimmingIncompleteUTF8(
    base: UnsafeRawPointer, from: Int, to: Int
  ) throws(JSONParsingError) -> Int {
    var index = to &- 1
    let lowest = Swift.max(from, to &- 4)
    while index >= lowest {
      let byte = base.load(fromByteOffset: index, as: UInt8.self)
      if byte < .utf8ContinuationFloor { return to }
      if byte >= .utf8TwoByteFloor {
        let needed = Self.sequenceLength(byte)
        let available = to &- index
        return available >= needed ? to : index
      }
      index &-= 1
    }
    return to
  }

  @inlinable
  mutating func holdPendingUTF8(
    base: UnsafeRawPointer, from: Int, to: Int
  ) throws(JSONParsingError) {
    let count = to &- from
    guard count <= 4 else { throw self.error(.invalidUTF8, at: from) }
    // An invalid lead can be rejected before anything is held, which leaves completion with only
    // the second byte constraints to check.
    let lead = base.load(fromByteOffset: from, as: UInt8.self)
    guard lead >= .utf8TwoByteMinimum, lead <= .utf8LeadCeiling else {
      throw self.error(.invalidUTF8, at: from)
    }
    for offset in 0..<count {
      self.buffer[self.buffer.count &- 8 &+ offset] =
        base.load(fromByteOffset: from &+ offset, as: UInt8.self)
    }
    self.pendingUTF8Count = count
  }

  // Only continuation bytes are taken, and the reassembled sequence goes through the same
  // validation a contiguous one would. Filling blindly swallowed whatever byte came next — a
  // closing quote, structurally — and emitting without validating accepted overlongs, encoded
  // surrogates and out of range leads whenever the split fell inside the sequence, which is
  // every sequence when fed byte by byte.
  @inlinable
  mutating func completePendingUTF8<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, count n: Int, into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    let tailStart = self.buffer.count &- 8
    let leadAt = -self.pendingUTF8Count
    let lead = self.buffer[tailStart]
    let needed = Self.sequenceLength(lead)
    var have = self.pendingUTF8Count
    var i = 0
    while have < needed && i < n {
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      guard byte >= .utf8ContinuationFloor, byte < .utf8TwoByteFloor else { break }
      self.buffer[tailStart &+ have] = byte
      have &+= 1
      i &+= 1
    }
    if have < needed {
      if i == n {
        self.pendingUTF8Count = have
        return n
      }
      // The next byte is not a continuation, so the sequence is truncated.
      throw self.error(.invalidUTF8, at: leadAt)
    }
    self.pendingUTF8Count = 0
    // The fill loop admitted only continuation bytes and the hold rejected invalid leads, so the
    // sequence is valid unless its second byte encodes an overlong, a surrogate or a scalar past
    // U+10FFFF — the same second byte constraints the contiguous validator applies, without its
    // ASCII prescan, which measured 32% of byte fed non-ASCII throughput.
    if needed > 1 {
      let second = self.buffer[tailStart &+ 1]
      switch lead {
      case .utf8ThreeByteFloor:
        guard second >= .utf8ThreeByteLowerBound else { throw self.error(.invalidUTF8, at: leadAt) }
      case .utf8SurrogateLead:
        guard second <= .utf8SurrogateCeiling else { throw self.error(.invalidUTF8, at: leadAt) }
      case .utf8FourByteFloor:
        guard second >= .utf8FourByteLowerBound else { throw self.error(.invalidUTF8, at: leadAt) }
      case .utf8MaximumLead:
        guard second <= .utf8MaximumSecond else { throw self.error(.invalidUTF8, at: leadAt) }
      default:
        break
      }
    }
    let slice = UnsafeBufferPointer(start: self.buffer.baseAddress! + tailStart, count: needed)
    sink.stringChunk(Span(_unsafeElements: slice))
    return i
  }

  // The three lead thresholds counted rather than branched between. A lead's length is how many
  // of `0xC0`, `0xE0`, `0xF0` it reaches, plus one, and the three tests are independent, so this
  // is `cmp`/`adc` three times with nothing to predict -- where the four-compare ladder it
  // replaces was four branches choosing between four constants. A continuation byte reaches none
  // of them and answers 1, which is what the ladder's leading `lead < 0x80` arm answered for it,
  // so the two agree on all 256 bytes; `LookupTableTests` holds this to the ladder exhaustively.
  //
  // A packed nibble table -- one length per nibble of `0x4322_1111_1111_1111`, indexed by
  // `lead >> 4` -- is fewer operations still and was measured first. It lost, by 2 to 4% across
  // the whole corpus including payloads with no non-ASCII byte in them at all, because its
  // 64-bit immediate is ten bytes of `movabs` at every site this inlines into, and one of those
  // sites is `completePendingUTF8`, which inlines into `parse`. Nothing here is hot enough to
  // pay for growing the dispatcher: the branches this removes were never taken on those payloads
  // in the first place. The counting form is the same size as the ladder and wins where the
  // ladder was actually walked -- `Twitter` +1.4%, `Twitter escaped` +2.0%, `LLM message` +1.8%
  // -- at the cost of `Canada` -3.7%, which is the same dispatcher-layout effect in the other
  // direction on a payload with no strings to speak of.
  @inlinable
  package static func sequenceLength(_ lead: UInt8) -> Int {
    var length = 1
    if lead >= .utf8TwoByteFloor { length &+= 1 }
    if lead >= .utf8ThreeByteFloor { length &+= 1 }
    if lead >= .utf8FourByteFloor { length &+= 1 }
    return length
  }

  // The two guards inline at every call site and settle every ASCII run; a run with a high bit
  // goes out of line to the vector validator, and only an invalid one reaches the scalar walk
  // behind it, which exists now to name the byte. The split is what keeps the string loop's
  // code where it was: with the validator call inlined there too, the byte fed rows paid 2-5%.
  @inlinable
  @inline(__always)
  mutating func validateUTF8IfNeeded(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    containsNonASCII: Bool,
    reportAt: Int?
  ) throws(JSONParsingError) {
    guard containsNonASCII else { return }
    try self.validateNonASCIIRun(base: base, from: from, to: to, reportAt: reportAt)
  }

  @inlinable
  @inline(never)
  mutating func validateNonASCIIRun(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    reportAt: Int?
  ) throws(JSONParsingError) {
    if streamValidateUTF8(base: base, from: from, to: to) { return }
    var i = from
    while i < to {
      let lead = base.load(fromByteOffset: i, as: UInt8.self)
      if lead < .utf8ContinuationFloor {
        i &+= 1
        continue
      }
      guard lead >= .utf8TwoByteMinimum, lead <= .utf8LeadCeiling else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      let needed = Self.sequenceLength(lead)
      guard i &+ needed <= to else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      for offset in 1..<needed {
        let continuation = base.load(fromByteOffset: i &+ offset, as: UInt8.self)
        guard continuation >= .utf8ContinuationFloor, continuation < .utf8TwoByteFloor else {
          throw self.error(.invalidUTF8, at: reportAt ?? i)
        }
      }
      let second = base.load(fromByteOffset: i &+ 1, as: UInt8.self)
      switch lead {
      case .utf8ThreeByteFloor:
        guard second >= .utf8ThreeByteLowerBound else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      case .utf8SurrogateLead:
        guard second <= .utf8SurrogateCeiling else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      case .utf8FourByteFloor:
        guard second >= .utf8FourByteLowerBound else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      case .utf8MaximumLead:
        guard second <= .utf8MaximumSecond else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      default:
        break
      }
      i &+= needed
    }
  }

  // MARK: Emission helpers

  // The last sixteen bytes of the buffer are reserved: eight for a UTF-8 sequence straddling a
  // chunk boundary and four for an escape being decoded. Neither can be live at once, and
  // `appendToBuffer` keeps a buffered key or number below them.
  @usableFromInline static let reservedTailByteCount = 16

  @inlinable
  var escapeScratchOffset: Int { self.buffer.count &- 4 }

  @inlinable
  mutating func emitScalar<Sink: StreamParseSink & ~Copyable>(
    _ value: UInt32, into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    let at = self.escapeScratchOffset
    let count: Int
    if value < .utf8OneByteCeiling {
      self.buffer[at] = UInt8(value)
      count = 1
    } else if value < .utf8TwoByteCeiling {
      self.buffer[at] = UInt8(0xC0 | (value >> 6))
      self.buffer[at &+ 1] = UInt8(0x80 | (value & .utf8ContinuationMask))
      count = 2
    } else if value < .utf8ThreeByteCeiling {
      self.buffer[at] = UInt8(0xE0 | (value >> 12))
      self.buffer[at &+ 1] = UInt8(0x80 | ((value >> 6) & .utf8ContinuationMask))
      self.buffer[at &+ 2] = UInt8(0x80 | (value & .utf8ContinuationMask))
      count = 3
    } else {
      self.buffer[at] = UInt8(0xF0 | (value >> 18))
      self.buffer[at &+ 1] = UInt8(0x80 | ((value >> 12) & .utf8ContinuationMask))
      self.buffer[at &+ 2] = UInt8(0x80 | ((value >> 6) & .utf8ContinuationMask))
      self.buffer[at &+ 3] = UInt8(0x80 | (value & .utf8ContinuationMask))
      count = 4
    }
    try self.emitScratch(count: count, into: &sink, reportAt: reportAt)
  }

  @inlinable
  mutating func emitDecoded<Sink: StreamParseSink & ~Copyable>(
    byte: UInt8, into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    self.buffer[self.escapeScratchOffset] = byte
    try self.emitScratch(count: 1, into: &sink, reportAt: reportAt)
  }

  @inlinable
  mutating func emitScratch<Sink: StreamParseSink & ~Copyable>(
    count: Int, into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    let at = self.escapeScratchOffset
    if self.isKeyToken {
      try self.appendToBuffer(
        base: UnsafeRawPointer(self.buffer.baseAddress! + at), from: 0, count: count,
        reportAt: reportAt
      )
      return
    }
    let slice = UnsafeBufferPointer(start: self.buffer.baseAddress! + at, count: count)
    sink.stringChunk(Span(_unsafeElements: slice))
  }

  // MARK: Container stack

  @inlinable
  @inline(__always)
  var topIsObject: Bool {
    Self.topIsObject(depth: self.depth, containers: self.containers)
  }

  // `depth` as a shift amount. The conversion is truncating rather than checked because
  // `UInt64(depth)` is a *trapping* conversion -- `depth` is an `Int` and a negative one has no
  // `UInt64` -- and the optimiser cannot prove the parser never makes it negative, so it planted
  // `test`/`js` and a `ud2` block at both container pushes, the two hottest structural bytes in
  // any document. `depth` is bounded to `0 ..< maximumDepth` by the guard immediately above each
  // use, so nothing is being reinterpreted here; the trap edge was pure tax, and a trap edge in
  // the middle of a block also stops the surrounding compares from being if-converted.
  @inlinable
  @inline(__always)
  static func shiftAmount(_ depth: Int) -> UInt64 {
    UInt64(truncatingIfNeeded: depth)
  }

  // `depth` never exceeds `maximumDepth`, so the masking shift is exact and skips the overshift
  // guard a smart shift carries. False at depth zero, which is what every caller wants there.
  @inlinable
  @inline(__always)
  static func topIsObject(depth: Int, containers: UInt64) -> Bool {
    depth > 0 && (containers &>> UInt64(depth &- 1)) & 1 == 1
  }

  // MARK: Diagnostics

  // Every error reports the absolute offset of the byte it was detected at, so the position a
  // document fails at does not depend on how it was chunked. Errors detected at a token's
  // completion — a key validated whole, a number parsed whole — name the token's final byte.
  @inlinable
  func error(_ reason: JSONParsingError.Reason, at offset: Int) -> JSONParsingError {
    JSONParsingError(reason: reason, byteOffset: self.consumedByteCount &+ offset)
  }

  @inlinable
  mutating func checkSink<Sink: StreamParseSink & ~Copyable>(
    _ sink: inout Sink, at offset: Int
  ) throws(JSONParsingError) {
    if let failure = sink.streamFailure {
      throw JSONParsingError(
        reason: .sinkRejectedToken(failure), byteOffset: self.consumedByteCount &+ offset
      )
    }
  }

  @inlinable
  static func hexValue(_ byte: UInt8) -> UInt32? {
    switch byte {
    case .asciiZero ... .asciiNine: UInt32(byte &- .asciiZero)
    case .asciiLowerA ... .asciiLowerF: UInt32(byte &- .asciiLowerA &+ 10)
    case .asciiUpperA ... .asciiUpperF: UInt32(byte &- .asciiUpperA &+ 10)
    default: nil
    }
  }
}
