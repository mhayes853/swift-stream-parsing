// The event recorder. Every path through the parser — the byte fed dispatcher, the windowed
// walk and its shape loops — records what it would have said to the sink into one scratch
// array and hands it over in batches: when the scratch fills, at the end of every `parse` and
// `finish` call, before a grammar error is thrown (events before the error were delivered
// before it on the call-per-event path too), and immediately after any record whose bytes
// live in the parser's buffer, because the buffer is reused by the next cut token or escape.
//
// A rejection is read once per flush, at the `end` the record carries: the byte after the
// event, which is where the dispatcher's cursor sat when it read the sink after every token.
// The design and its measurements are in NEW_ARCHITECTURE.md, "Event batching".
extension JSONParser {
  @usableFromInline static var eventBatchCapacity: Int { 256 }

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
    if self.eventCount == Self.eventBatchCapacity { try self.flushEvents(into: &sink) }
    self.eventScratch[self.eventCount] = StreamEventRecord(
      kind: kind, start: start, length: length, end: end, extra: extra, source: source
    )
    self.eventCount &+= 1
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
    if self.eventCount == Self.eventBatchCapacity { try self.flushEvents(into: &sink) }
    self.eventScratch[self.eventCount] = StreamEventRecord(
      kind: .number, start: start, length: length, end: end, source: source
    )
    self.eventInfoScratch[self.eventCount] = info
    self.eventCount &+= 1
  }

  // The same, with the count held by the caller: a loop that records on every iteration keeps
  // it in a register this way, where reading it back from `self` after each store through the
  // scratch pointer — which the optimizer must assume may alias `self` — is a store-to-load
  // round trip per record. The caller owns `self.eventCount` while it holds the count and
  // writes it back on every exit.
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
    if count == Self.eventBatchCapacity {
      self.eventCount = count
      count = 0
      try self.deliverEvents(into: &sink)
    }
    events[count] = StreamEventRecord(kind: kind, start: start, length: length, end: end)
    count &+= 1
  }

  // The scratch pointers are the caller's locals too, for the same reason: loaded from `self`
  // they are re-read after every store through them.
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
    if count == Self.eventBatchCapacity {
      self.eventCount = count
      count = 0
      try self.deliverEvents(into: &sink)
    }
    events[count] = StreamEventRecord(kind: .number, start: start, length: length, end: end)
    infos[count] = info
    count &+= 1
  }

  // A string chunk of at most four bytes — a decoded escape, a UTF-8 sequence rejoined across
  // chunks — carried in the record, so nothing points at scratch that the next escape reuses.
  @inlinable
  @inline(__always)
  mutating func recordInlineChunk<Sink: StreamParseSink & ~Copyable>(
    _ bytes: UnsafeRawPointer, count: Int, end: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    // Both scratch regions this is called with — the escape scratch and the UTF-8 tail — are
    // at least four bytes long, so one word load and a mask replace a copy (which the
    // optimizer turned into a `memmove` call per `\u` escape).
    let word = bytes.loadUnaligned(as: UInt32.self)
    let packed = count == 4 ? word : word & ((1 &<< (8 &* UInt32(truncatingIfNeeded: count))) &- 1)
    try self.record(.stringChunk, start: 0, length: count, end: end, extra: packed, source: .inline, into: &sink)
  }

  // Hands the recorded events to the sink and reads its failure once. A sink that stops early
  // must have recorded a failure; the rejection is reported at the event it stopped at — the
  // byte after it, or, for a whole string, the byte after its opening quote — and otherwise at
  // the batch's last event.
  // A string whose opening quote was the chunk's last byte: its `stringBegin` is delivered
  // now rather than with the next chunk, so a snapshot between the two sees the string
  // opened — the byte level observability the call-per-event path had.
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

  // One string byte, handed over without touching the scratch. Out of line by force and for the
  // reason `deliverEvents` is: `parse(byte:)` is the dispatcher every byte fed document walks
  // once per byte, and its inlining is the least stable thing in this parser — an always-inline
  // delivery tried in an earlier round grew `parse` to a 1,388 byte specialisation with 26 calls
  // and gave back everything it won. This stays one call from `parse(byte:)`, and the batch it
  // builds lives in this frame rather than in `self`.
  //
  // `bufferBase` is the parser's buffer as always; nothing in a one-record inline batch reads it,
  // but the batch's shape does not vary by path.
  @inlinable
  @inline(never)
  mutating func deliverStringByte<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8, into sink: inout Sink
  ) throws(JSONParsingError) {
    // Slot zero of the scratch rather than a local: `withUnsafePointer` on a local record spawns
    // a second out-of-line closure, so the fast path cost two calls instead of one. The scratch's
    // address is already stable and `eventCount` is zero by the caller's guard, so slot zero is
    // free and nothing reads it until the next record is written there anyway.
    self.eventScratch[0] = StreamEventRecord(
      kind: .stringChunk, start: 0, length: 1, end: 1, extra: UInt32(byte), source: .inline
    )
    let batch = StreamEventBatch(
      recordBase: UnsafePointer(self.eventScratch),
      infoBase: UnsafePointer(self.eventInfoScratch),
      count: 1,
      bytesBase: self.chunkBase.assumingMemoryBound(to: UInt8.self),
      bufferBase: UnsafePointer(self.buffer.baseAddress!)
    )
    let taken = sink.events(batch)
    if taken < 1 {
      precondition(
        sink.streamFailure != nil,
        "StreamParseSink.events returned 0 of 1 without recording a failure."
      )
    }
    try self.checkSink(&sink, at: 1)
    self.consumedByteCount &+= 1
  }

  // The empty check is inline at the call sites — the byte fed path flushes after every byte,
  // and most bytes record nothing — and the delivery is out of line.
  @inlinable
  @inline(__always)
  mutating func flushEvents<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink
  ) throws(JSONParsingError) {
    if self.eventCount > 0 { try self.deliverEvents(into: &sink) }
  }

  @inlinable
  @inline(never)
  mutating func deliverEvents<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink
  ) throws(JSONParsingError) {
    let recorded = self.eventCount
    self.eventCount = 0
    let batch = StreamEventBatch(
      recordBase: UnsafePointer(self.eventScratch), infoBase: UnsafePointer(self.eventInfoScratch),
      count: recorded, bytesBase: self.chunkBase.assumingMemoryBound(to: UInt8.self),
      bufferBase: UnsafePointer(self.buffer.baseAddress!)
    )
    let taken = sink.events(batch)
    if taken < recorded {
      precondition(
        sink.streamFailure != nil,
        "StreamParseSink.events returned \(taken) of \(recorded) without recording a failure."
      )
      let record = self.eventScratch[taken]
      try self.checkSink(&sink, at: record.kind == .string ? Int(record.start) : Int(record.end))
    }
    try self.checkSink(&sink, at: Int(self.eventScratch[recorded &- 1].end))
  }
}
