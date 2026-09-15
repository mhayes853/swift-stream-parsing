// The emission layer: direct calls into the sink's per-token methods at the lex points. A rejected
// token throws at the byte after it, a rejected whole string at its content start. The batching
// recorder this replaced lost on every route (NEW_ARCHITECTURE.md, "The fusion series"). The
// `record` names and shapes survive on purpose: every layout decision was measured against call
// sites of this shape, and a constant `kind` folds each to one primitive call.
extension JSONParser {
  // A span over the token's bytes, from the caller's base (already in a register), not a field.
  // Static and tied to `base`: `@_lifetime(borrow self)` on a body that does not read `self`
  // tripped a SIL ownership verifier crash in `consumeStructuralRun<PartialSink>`.
  @inlinable
  @inline(__always)
  @_lifetime(borrow base)
  static func emissionSpan(
    _ base: UnsafeRawPointer, _ start: Int, _ length: Int
  ) -> Span<UInt8> {
    _overrideLifetime(
      Span(
        _unsafeElements: UnsafeBufferPointer(
          start: (base + start).assumingMemoryBound(to: UInt8.self), count: length
        )
      ),
      borrowing: base
    )
  }

  // A load and a predicted-not-taken branch per token; the throw's expansion is out of line, as
  // `fail`'s is, so no emission site carries the construction.
  @inlinable
  @inline(__always)
  mutating func checkEmission<Sink: StreamParseSink & ~Copyable>(
    _ sink: inout Sink, at offset: Int
  ) throws(JSONParsingError) {
    if let failure = sink.streamFailure {
      try Self.failSinkRejection(failure, byteOffset: self.consumedByteCount &+ offset)
    }
  }

  @inlinable
  @inline(never)
  static func failSinkRejection(
    _ failure: StreamSinkFailure, byteOffset: Int
  ) throws(JSONParsingError) -> Never {
    throw JSONParsingError(reason: .sinkRejectedToken(failure), byteOffset: byteOffset)
  }

  // The lifetime signal: at the end of every parse call, before an error propagates, and at
  // finish. A failure the sink only discovers now (a batching adapter's consumer refusing a
  // deferred event) surfaces here, at the position the parse reached.
  @inlinable
  @inline(__always)
  mutating func commitSink<Sink: StreamParseSink & ~Copyable>(
    chunkEnd n: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    sink.commit()
    try self.checkEmission(&sink, at: n)
  }

  // The commit on an error path. A `throw` in a `catch` replaces the in-flight error, so a sink
  // rejection (already thrown at its token) must not be re-checked here; only a late rejection
  // surfacing at the commit -- earlier in the document than the grammar error -- outranks it.
  @inlinable
  @inline(__always)
  mutating func commitSink<Sink: StreamParseSink & ~Copyable>(
    chunkEnd n: Int, replacing error: JSONParsingError, into sink: inout Sink
  ) throws(JSONParsingError) -> Never {
    sink.commit()
    if case .sinkRejectedToken = error.reason { throw error }
    try self.checkEmission(&sink, at: n)
    throw error
  }

  @inlinable
  @inline(__always)
  mutating func record<Sink: StreamParseSink & ~Copyable>(
    _ kind: StreamEventRecord.Kind,
    start: Int,
    length: Int,
    end: Int,
    extra: UInt32 = 0,
    base: UnsafeRawPointer,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    switch kind {
    // Open dispositions are discarded (legal by the advisory contract); sites that can honor a
    // skip use `recordContainerOpen`. The one open site left here is `consumeNumericArray`'s `[`.
    case .beginObject: _ = sink.beginObject()
    case .endObject: sink.endObject()
    case .beginArray: _ = sink.beginArray()
    case .endArray: sink.endArray()
    case .key: sink.key(Self.emissionSpan(base, start, length))
    case .stringBegin: sink.stringBegin()
    case .stringChunk: sink.stringChunk(Self.emissionSpan(base, start, length))
    case .stringEnd: sink.stringEnd()
    case .string: sink.string(Self.emissionSpan(base, start, length))
    case .boolean: sink.boolean(extra != 0)
    case .null: sink.null()
    // Numbers always come through `recordNumber`. `kind` is a literal at every site, so the trap
    // folds away; it keeps a future caller from getting a default-constructed `NumberInfo`.
    case .number: preconditionFailure("numbers are recorded through recordNumber")
    }
    // A rejected whole string reports at its content start — the byte after the opening quote —
    // and every other token at the byte after itself, exactly where batch delivery reported.
    try self.checkEmission(&sink, at: kind == .string ? start : end)
  }

  // A container open whose site can honor the sink's answer: the same emission and failure
  // check as `record`, with the disposition handed back so the caller can enter skip mode.
  @inlinable
  @inline(__always)
  mutating func recordContainerOpen<Sink: StreamParseSink & ~Copyable>(
    object: Bool, end: Int, into sink: inout Sink
  ) throws(JSONParsingError) -> StreamContainerDisposition {
    let disposition = object ? sink.beginObject() : sink.beginArray()
    try self.checkEmission(&sink, at: end)
    return disposition
  }

  @inlinable
  @inline(__always)
  mutating func recordNumber<Sink: StreamParseSink & ~Copyable>(
    start: Int,
    length: Int,
    end: Int,
    base: UnsafeRawPointer,
    info: NumberInfo,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    sink.number(Self.emissionSpan(base, start, length), info: info)
    try self.checkEmission(&sink, at: end)
  }

  // A chunk of at most four bytes (a decoded escape, a rejoined UTF-8 sequence), stored whole into
  // the reserved scratch. Measured: a `withUnsafeBytes(of: &word)` closure instead cost -10%
  // escape-heavy / -14% byte-fed; see NEW_ARCHITECTURE.md, "The escape scratch".
  @inlinable
  @inline(__always)
  mutating func recordInlineChunk<Sink: StreamParseSink & ~Copyable>(
    _ word: UInt64, count: Int, end: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    let scratch = self.scratchBase
    // The whole word, unconditionally, in one unaligned `str`; the high bytes land unread in the
    // reserved scratch. Measured: a `while at < count` loop was 6-7% slower on Twitter escaped.
    UnsafeMutableRawPointer(scratch).storeBytes(of: word, as: UInt64.self)
    sink.stringChunk(Self.scratchSpan(UnsafeRawPointer(scratch), count))
    try self.checkEmission(&sink, at: end)
  }

  @inlinable
  @inline(__always)
  @_lifetime(borrow bytes)
  static func scratchSpan(_ bytes: UnsafeRawPointer, _ count: Int) -> Span<UInt8> {
    _overrideLifetime(
      Span(
        _unsafeElements: UnsafeBufferPointer(
          start: bytes.assumingMemoryBound(to: UInt8.self), count: count
        )
      ),
      borrowing: bytes
    )
  }

  // A string whose opening quote was the chunk's last byte gets its `stringBegin` at the chunk's
  // end, not the next chunk's start, so a snapshot between the two sees the string opened.
  @inlinable
  @inline(__always)
  mutating func settlePendingStringBegin<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, chunkEnd n: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    if self.stringBeginPending {
      self.stringBeginPending = false
      try self.record(.stringBegin, start: Swift.max(n &- 1, 0), length: 1, end: n, base: base, into: &sink)
    }
  }

  // One string byte, the shape byte-fed input is mostly made of. Out of line: `parse(byte:)`'s
  // inlining is the least stable thing in the parser. The byte borrows the reserved scratch (no
  // escape is in flight inside a clean string byte), so the call's commit lands here, doubling as
  // the chunk's failure check: a no-op `commit()` leaves the body what it was.
  @inlinable
  @inline(never)
  mutating func deliverStringByte<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8, into sink: inout Sink
  ) throws(JSONParsingError) {
    let scratch = self.scratchBase
    scratch[0] = byte
    sink.stringChunk(Self.scratchSpan(UnsafeRawPointer(scratch), 1))
    try self.commitSink(chunkEnd: 1, into: &sink)
    self.consumedByteCount &+= 1
  }

}
