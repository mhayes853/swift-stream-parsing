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
// primitive call per site.
extension JSONParser {
  // A span over the token's bytes. The base is the caller's, not a field: every emission site
  // is inside a run loop that already holds the chunk pointer in a register (or, for a token
  // reassembled in the parser's buffer, the buffer's own base), so reading it back out of the
  // parser was a load from a cache line the loop otherwise never touched. The field it replaced
  // (`chunkBase`) had exactly one reader, which was this function.
  // Static, and tied to the base rather than to `self`: with the pointer arriving as an
  // argument there is nothing of the parser left in the result, and keeping the old
  // `@_lifetime(borrow self)` shape on a body that no longer reads `self` tripped a SIL
  // ownership verifier crash in the `PartialSink` specialization of `consumeStructuralRun`.
  // This is `scratchSpan`'s shape, which the escape path has always used.
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
    base: UnsafeRawPointer,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    switch kind {
    // Open dispositions are discarded here; the sites that can honor a skip go through
    // `recordContainerOpen` below. Discarding is legal by the advisory contract — the one
    // remaining open site that records through here (`consumeNumericArray`'s nested `[`, which
    // a skipping sink never streams into) just parses the subtree it was told it could skip.
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
    // Numbers carry their parsed info and always come through `recordNumber`.
    case .number: sink.number(Self.emissionSpan(base, start, length), info: NumberInfo())
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

  // A string chunk of at most four bytes -- a decoded escape, a UTF-8 sequence rejoined across
  // chunks -- carried here in a register and stored whole into the parser's reserved scratch,
  // whose address is stable and already in memory. There is no closure: the earlier
  // `withUnsafeBytes(of: &word)` form cost -10% on escape-heavy corpora and -14% on byte-fed
  // ones, because it spilled the word to a fresh stack slot per escaped byte and captured the
  // sink `inout` across the call.
  //
  // Back to `@inline(__always)`, which is what it always was. The reason it had to be forced out
  // of line -- the spilled stack slot landing in `consumeStringRun`'s frame, taking it from 41
  // stack accesses to 73 -- is gone with the local, so the callee no longer has to pay a call
  // per escape to protect the parser's most brittle register budget.
  @inlinable
  @inline(__always)
  mutating func recordInlineChunk<Sink: StreamParseSink & ~Copyable>(
    _ word: UInt64, count: Int, end: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    let scratch = self.scratchBase
    // The whole word, unconditionally, in one unaligned `str`. The scratch is a reserved eight
    // bytes, so writing the high bytes the sink will not look at is free.
    //
    // Storing only the low `count` bytes with a `while at < count` loop instead measured worse
    // by a wide margin on escape-dense corpora: Twitter escaped bulk 1289 -> 1374 MB/s and its
    // 16KB rows 1284 -> 1379, GSoC 2018 bulk 4225 -> 4338, i.e. a -2.2% regression against the
    // pre-layout parser became a +4.3% win. Note the mechanism is *not* code size at the call
    // site -- every `consumeStringRun` specialisation is byte-identical between the two forms
    // (6679 instructions, 472 stack accesses either way); the only function that changes is this
    // one, 46 -> 38 instructions. The loop is simply not worth its branches once per escape.
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

  // A string whose opening quote was the chunk's last byte: its `stringBegin` is delivered at
  // the chunk's end rather than held to the next one, so a snapshot between the two sees the
  // string opened — the byte level observability the call-per-event path had, unchanged.
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

  // One string byte, the shape byte fed input is mostly made of. Out of line by force and for
  // the reason it always was: `parse(byte:)` is the dispatcher every byte fed document walks
  // once per byte, and its inlining is the least stable thing in this parser. The byte borrows
  // the reserved scratch for a stable address -- dead on this path, since no escape is in
  // progress inside a clean string byte -- and the sink gets the same one-byte chunk the
  // one-record batch used to carry.
  @inlinable
  @inline(never)
  mutating func deliverStringByte<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8, into sink: inout Sink
  ) throws(JSONParsingError) {
    let scratch = self.scratchBase
    scratch[0] = byte
    sink.stringChunk(Self.scratchSpan(UnsafeRawPointer(scratch), 1))
    try self.checkEmission(&sink, at: 1)
    self.consumedByteCount &+= 1
  }

}
