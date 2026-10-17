// Batching as an adapter: records the per-token calls and flushes a `StreamEventBatch` to its
// consumer every `batchCapacity` events and at `commit()`. For boundaries fusion cannot cross
// (another thread, async sequences, FFI, replay tooling); not a fast path. Looser than direct
// delivery: bytes are copied (a batch is valid for its `events` call); a rejection surfaces at the
// next flush, reported at the token current then, and `StreamEventRecord.end` is unpopulated; and
// skips are not honored.
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

  // The tail both `append`s share: a full batch is delivered as soon as it fills.
  @inline(__always)
  private mutating func recordAppended() {
    if self.records.count == Self.batchCapacity { self.flush() }
  }

  private mutating func append(_ kind: StreamEventRecord.Kind, extra: UInt32 = 0) {
    self.records.append(StreamEventRecord(kind: kind, start: 0, length: 0, end: 0, extra: extra))
    self.infos.append(NumberInfo())
    self.recordAppended()
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
    self.recordAppended()
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
    // The consumer call is deliberately outside every array borrow: inside three nested
    // `withUnsafeBufferPointer`s, a consumer feeding this sink would mutate the arrays the live
    // batch points into. Holding the arrays across the call keeps the pointers valid, and a
    // re-entrant append copies on write instead of reallocating under the batch.
    let recordCount = self.records.count
    let recordBase = self.records.withUnsafeBufferPointer { $0.baseAddress.unsafelyUnwrapped }
    let infoBase = self.infos.withUnsafeBufferPointer { $0.baseAddress.unsafelyUnwrapped }
    let byteBase = self.bytes.withUnsafeBufferPointer { $0.baseAddress }
    let taken = withExtendedLifetime((self.records, self.infos, self.bytes)) {
      // An all-structural batch has no bytes; the base only needs to be valid to add zero to.
      withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1) { fallback in
        let base = byteBase ?? UnsafePointer(fallback.baseAddress.unsafelyUnwrapped)
        let batch = StreamEventBatch(
          replaying: recordBase,
          infoBase: infoBase,
          count: recordCount,
          bytesBase: base,
          bufferBase: base
        )
        return self.consumer.events(batch)
      }
    }
    if taken < recordCount {
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

  // Always `.stream`: with deferred delivery the consumer cannot be asked about a subtree it has
  // not seen, and the replay discards dispositions (legal by the advisory contract), so a subtree
  // it would have skipped is parsed and delivered in full.
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
