// Batching, demoted from protocol requirement to adapter: a sink that implements the per-token
// methods by recording `StreamEventRecord`s and flushing a `StreamEventBatch` to its consumer
// every `batchCapacity` events and at `commit()` — the parser's old internal transport,
// relocated behind the protocol it used to be.
//
// This exists for the boundaries fusion cannot cross: a consumer on another thread, an async
// event sequence, FFI, record/replay tooling. It is NOT the fast path and does not try to be —
// a sink that can be specialized into the parse loop should conform to `StreamParseSink`
// directly and skip the transport entirely.
//
// Three contracts are deliberately looser than direct delivery:
//
// - Bytes are copied. A per-token span borrows parser memory the adapter cannot hold past the
//   call, and the span carries no offset into the chunk, so records into live input are not
//   reconstructible from out here. Every consumer this adapter serves crosses a boundary the
//   bytes could not have stayed borrowed across anyway; the batch the consumer sees references
//   the adapter's own scratch and is valid for the duration of its `events` call.
// - Rejection surfaces at the next flush. The parser polls `streamFailure` per token, but a
//   deferred event is only refused when the consumer sees it, up to a batch later; the parse
//   stops there, and the reported offset is the token that was current at the flush, not the
//   one refused. `StreamEventRecord.end` is likewise not populated: it was a chunk offset only
//   the parser's own recorder could know.
// - Skips are not honored. The adapter answers `.stream` at every container open (its consumer
//   has not seen the open yet, so it cannot be asked), and the replay on the far side discards
//   the consumer's dispositions — a subtree the consumer's sink would have skipped is parsed,
//   validated and delivered in full on this path.
public protocol StreamEventBatchConsumer: ~Copyable {
  /// Consumes events in order and returns how many were taken: `batch.count` when all were, or
  /// the index of the first event refused after recording ``streamFailure``.
  mutating func events(_ batch: borrowing StreamEventBatch) -> Int

  var streamFailure: StreamSinkFailure? { get }
}

public struct StreamEventBatchingSink<Consumer: StreamEventBatchConsumer & ~Copyable>:
  ~Copyable, StreamParseSink
{
  /// The parser's own flush threshold: past the knee of the batch-size sweep, and the largest
  /// capacity that measured free.
  public static var batchCapacity: Int { 256 }

  public var consumer: Consumer
  public private(set) var streamFailure: StreamSinkFailure?

  // Parallel by record index, as `StreamEventBatch.info(of:)` reads them: the info slot for a
  // non-number record is simply never read.
  private var records: ContiguousArray<StreamEventRecord> = []
  private var infos: ContiguousArray<NumberInfo> = []
  private var bytes: ContiguousArray<UInt8> = []

  public init(consumer: consuming Consumer) {
    self.consumer = consumer
    self.records.reserveCapacity(Self.batchCapacity)
    self.infos.reserveCapacity(Self.batchCapacity)
  }

  // MARK: Recording

  private mutating func append(_ kind: StreamEventRecord.Kind, extra: UInt32 = 0) {
    self.records.append(StreamEventRecord(kind: kind, start: 0, length: 0, end: 0, extra: extra))
    self.infos.append(NumberInfo())
    if self.records.count == Self.batchCapacity { self.flush() }
  }

  private mutating func append(
    _ kind: StreamEventRecord.Kind, copying bytes: Span<UInt8>, info: NumberInfo = NumberInfo()
  ) {
    let start = self.bytes.count
    for index in 0..<bytes.count {
      self.bytes.append(bytes[unchecked: index])
    }
    self.records.append(
      StreamEventRecord(kind: kind, start: start, length: bytes.count, end: 0)
    )
    self.infos.append(info)
    if self.records.count == Self.batchCapacity { self.flush() }
  }

  // MARK: Flushing

  // Delivers everything recorded and resets the scratch. The batch's spans reference the
  // adapter's own buffers, so the consumer's borrow is scoped to this call exactly as a sink's
  // is scoped to the parser's.
  private mutating func flush() {
    guard self.streamFailure == nil, !self.records.isEmpty else {
      self.reset()
      return
    }
    let taken = self.records.withUnsafeBufferPointer { records in
      self.infos.withUnsafeBufferPointer { infos in
        self.bytes.withUnsafeBufferPointer { bytes in
          // An all-structural batch has no bytes; the base only needs to be valid to add zero to.
          withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1) { fallback in
            let base = bytes.baseAddress
              ?? UnsafePointer(fallback.baseAddress.unsafelyUnwrapped)
            let batch = StreamEventBatch(
              replaying: records.baseAddress.unsafelyUnwrapped,
              infoBase: infos.baseAddress.unsafelyUnwrapped,
              count: records.count,
              bytesBase: base,
              bufferBase: base
            )
            return self.consumer.events(batch)
          }
        }
      }
    }
    if taken < self.records.count {
      // A consumer that refuses an event must say why; a refusal with no reason recorded is
      // reported as the mismatch it almost certainly is rather than dropped.
      self.streamFailure = self.consumer.streamFailure ?? StreamSinkFailure(reason: .typeMismatch)
    }
    self.reset()
  }

  private mutating func reset() {
    self.records.removeAll(keepingCapacity: true)
    self.infos.removeAll(keepingCapacity: true)
    self.bytes.removeAll(keepingCapacity: true)
  }

  // MARK: StreamParseSink

  // Always `.stream`: the transport's whole point is deferred delivery, so the consumer cannot
  // be asked about a subtree it has not seen yet, and the replay on the far side discards the
  // dispositions it collects (the advisory contract makes that legal). A third documented
  // looseness: a subtree the consumer's sink would have skipped is parsed — and its interior
  // grammar checked — in full on this path.
  public mutating func beginObject() -> StreamContainerDisposition {
    self.append(.beginObject)
    return .stream
  }
  public mutating func endObject() { self.append(.endObject) }
  public mutating func beginArray() -> StreamContainerDisposition {
    self.append(.beginArray)
    return .stream
  }
  public mutating func endArray() { self.append(.endArray) }
  public mutating func key(_ bytes: Span<UInt8>) { self.append(.key, copying: bytes) }
  public mutating func stringBegin() { self.append(.stringBegin) }
  public mutating func stringChunk(_ bytes: Span<UInt8>) {
    self.append(.stringChunk, copying: bytes)
  }
  public mutating func stringEnd() { self.append(.stringEnd) }
  public mutating func string(_ bytes: Span<UInt8>) { self.append(.string, copying: bytes) }
  public mutating func boolean(_ value: Bool) { self.append(.boolean, extra: value ? 1 : 0) }
  public mutating func null() { self.append(.null) }

  public mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.append(.number, copying: bytes, info: info)
  }

  /// The parser's lifetime signal: borrowed memory is going away, so everything deferred is
  /// delivered now. Also the natural final flush at end of input.
  public mutating func commit() { self.flush() }
}
