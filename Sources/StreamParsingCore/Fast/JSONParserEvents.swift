// The emission layer. Every path through the parser — the bulk dispatcher, the byte fed
// dispatcher, the windowed walk and its shape loops — used to *record* what it would have said
// to the sink into one scratch array and hand it over in batches. The fused slice priced that
// seam (NEW_ARCHITECTURE.md, "The fused slice") and the batch lost on every route measured, so
// these are now direct calls into the sink's per-token methods, made at the lex points, with
// the same spans a batch would have reconstructed and the same failure offsets batch delivery
// reported: a rejected token throws at the byte after it, a rejected whole string at its
// content start.
//
// The `record`/`recordNumber` names and signatures survive on purpose. Every layout decision in
// the dispatcher, the run loops and the shapes — what is inlined where, which locals live in
// registers — was measured against call sites of this shape, and each `record` is
// `@inline(__always)` with a constant `kind`, so the switch below folds to exactly one
// primitive call per site. The register-count variants keep their extra parameters as inert
// history until the scratch they described is deleted with the rest of the recorder.
extension JSONParser {
  // Sizes the (now idle) event scratch the parser still allocates; dies with it.
  @usableFromInline static var eventBatchCapacity: Int { 256 }

  // A span over the token's bytes: the chunk's own for `.input`, the parser's buffer for
  // `.parserBuffer` — exactly what `StreamEventBatch.bytes(of:)` handed the sink. Valid for the
  // duration of the primitive call it is passed to, which is the whole contract.
  @inlinable
  @inline(__always)
  @_lifetime(borrow self)
  func emissionSpan(
    _ source: StreamEventRecord.Source, _ start: Int, _ length: Int
  ) -> Span<UInt8> {
    let base =
      source == .input
      ? self.chunkBase
      : UnsafeRawPointer(self.buffer.baseAddress.unsafelyUnwrapped)
    return _overrideLifetime(
      Span(
        _unsafeElements: UnsafeBufferPointer(
          start: (base + start).assumingMemoryBound(to: UInt8.self), count: length
        )
      ),
      borrowing: self
    )
  }

  // The per-batch failure read, relocated to per token: a load and a predicted-not-taken
  // branch, with the throw's 25-instruction expansion out of line for the same reason `fail`'s
  // is — every emission site pays the compare, none carries the construction.
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

  // The lifetime signal, delivered wherever a batch used to be flushed because borrowed memory
  // was about to go away: the end of every parse call, before an error propagates (the sink's
  // state reflects everything ahead of the error, exactly as delivered events did), and at
  // finish. A failure the sink only discovers now — a batching adapter's consumer refusing a
  // deferred event — surfaces here, at the position the parse reached.
  @inlinable
  @inline(__always)
  mutating func commitSink<Sink: StreamParseSink & ~Copyable>(
    chunkEnd n: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    sink.commit()
    try self.checkEmission(&sink, at: n)
  }

  // The commit on an error path. A sink rejection was already thrown at its token with the
  // right offset, and a `throw` inside a `catch` *replaces* the in-flight error — so checking
  // the (still recorded) failure here again would re-report it at the chunk's end. Only a
  // failure that genuinely surfaced at the commit — a deferring sink's late rejection, which is
  // earlier in the document than the grammar error carried in — outranks the original.
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
    source: StreamEventRecord.Source = .input,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    switch kind {
    case .beginObject: sink.beginObject()
    case .endObject: sink.endObject()
    case .beginArray: sink.beginArray()
    case .endArray: sink.endArray()
    case .key: sink.key(self.emissionSpan(source, start, length))
    case .stringBegin: sink.stringBegin()
    case .stringChunk: sink.stringChunk(self.emissionSpan(source, start, length))
    case .stringEnd: sink.stringEnd()
    case .string: sink.string(self.emissionSpan(source, start, length))
    case .boolean: sink.boolean(extra != 0)
    case .null: sink.null()
    // Numbers carry their parsed info and always come through `recordNumber`.
    case .number: sink.number(self.emissionSpan(source, start, length), info: NumberInfo())
    }
    // A rejected whole string reports at its content start — the byte after the opening quote —
    // and every other token at the byte after itself, exactly where batch delivery reported.
    try self.checkEmission(&sink, at: kind == .string ? start : end)
  }

  @inlinable
  @inline(__always)
  mutating func recordNumber<Sink: StreamParseSink & ~Copyable>(
    start: Int,
    length: Int,
    end: Int,
    source: StreamEventRecord.Source = .input,
    info: NumberInfo,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    sink.number(self.emissionSpan(source, start, length), info: info)
    try self.checkEmission(&sink, at: end)
  }

  // The register-count forms the shape loops call. The count they maintained amortized scratch
  // flushes that no longer exist; the extra parameters are ignored and go when the scratch does.
  @inlinable
  @inline(__always)
  mutating func record<Sink: StreamParseSink & ~Copyable>(
    _ kind: StreamEventRecord.Kind,
    start: Int,
    length: Int,
    end: Int,
    events: UnsafeMutablePointer<StreamEventRecord>,
    count: inout Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    try self.record(kind, start: start, length: length, end: end, into: &sink)
  }

  @inlinable
  @inline(__always)
  mutating func recordNumber<Sink: StreamParseSink & ~Copyable>(
    start: Int,
    length: Int,
    end: Int,
    info: NumberInfo,
    events: UnsafeMutablePointer<StreamEventRecord>,
    infos: UnsafeMutablePointer<NumberInfo>,
    count: inout Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    try self.recordNumber(start: start, length: length, end: end, info: info, into: &sink)
  }

  // A string chunk of at most four bytes — a decoded escape, a UTF-8 sequence rejoined across
  // chunks — handed over directly from the scratch it was decoded into, which is alive for the
  // duration of the call. The word-packing the record needed is gone with the record.
  @inlinable
  @inline(__always)
  mutating func recordInlineChunk<Sink: StreamParseSink & ~Copyable>(
    _ bytes: UnsafeRawPointer, count: Int, end: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    sink.stringChunk(Self.scratchSpan(bytes, count))
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

  // A string whose opening quote was the chunk's last byte: its `stringBegin` is delivered at
  // the chunk's end rather than held to the next one, so a snapshot between the two sees the
  // string opened — the byte level observability the call-per-event path had, unchanged.
  @inlinable
  @inline(__always)
  mutating func settlePendingStringBegin<Sink: StreamParseSink & ~Copyable>(
    chunkEnd n: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    if self.stringBeginPending {
      self.stringBeginPending = false
      try self.record(.stringBegin, start: Swift.max(n &- 1, 0), length: 1, end: n, into: &sink)
    }
  }

  // One string byte, the shape byte fed input is mostly made of. Out of line by force and for
  // the reason it always was: `parse(byte:)` is the dispatcher every byte fed document walks
  // once per byte, and its inlining is the least stable thing in this parser. The byte borrows
  // the escape scratch for a stable address — dead on this path, since no escape is in progress
  // inside a clean string byte — and the sink gets the same one-byte chunk the one-record batch
  // used to carry.
  @inlinable
  @inline(never)
  mutating func deliverStringByte<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8, into sink: inout Sink
  ) throws(JSONParsingError) {
    let at = self.escapeScratchOffset
    self.buffer[at] = byte
    sink.stringChunk(
      Self.scratchSpan(UnsafeRawPointer(self.buffer.baseAddress.unsafelyUnwrapped + at), 1)
    )
    try self.checkEmission(&sink, at: 1)
    self.consumedByteCount &+= 1
  }

  // Dead weight kept callable while call sites are converted: emission is synchronous now, so
  // there is never anything to flush. The buffer-reuse flushes (`emitBufferedKey`,
  // `emitBufferedNumber`) are moot for the same reason — by the time the buffer is overwritten,
  // the sink has already consumed the span.
  @inlinable
  @inline(__always)
  mutating func flushEvents<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink
  ) throws(JSONParsingError) {}
}
