/// One parse event, recorded: what a single sink call would have carried, with its bytes as an
/// offset and length into one of the batch's byte sources rather than a span.
public struct StreamEventRecord: Hashable, Sendable {
  public enum Kind: UInt8, Sendable {
    case beginObject, endObject, beginArray, endArray
    case key, stringBegin, stringChunk, stringEnd
    case number, boolean, null
    /// A whole string value, complete in the chunk and escape-free: one record for `stringBegin`,
    /// `stringChunk` (omitted when empty) and `stringEnd`. A rejection is taken to be at
    /// `stringBegin` and reported at the byte after the opening quote.
    case string
  }

  /// Where a record's bytes live. Most are the parser's input; a token the chunk cut is
  /// reassembled in the parser's buffer; a decoded escape or a UTF-8 sequence rejoined across
  /// chunks is at most four bytes and is carried in the record itself.
  public enum Source: UInt8, Sendable {
    case input, parserBuffer, inline
  }

  public var kind: Kind
  public var source: Source
  /// Offset of the bytes within `source` (unused for `inline`).
  public var start: UInt32
  public var length: UInt32
  /// The byte offset, within the chunk being parsed, just past the event: where the parser
  /// reads the sink's failure, so a rejection reports where the single call path reported it.
  public var end: UInt32
  /// A `boolean` record's value; an `inline` record's bytes.
  public var extra: UInt32

  @inlinable
  public init(
    kind: Kind, start: Int, length: Int, end: Int, extra: UInt32 = 0, source: Source = .input
  ) {
    self.kind = kind
    self.source = source
    self.start = UInt32(truncatingIfNeeded: start)
    self.length = UInt32(truncatingIfNeeded: length)
    self.end = UInt32(truncatingIfNeeded: end)
    self.extra = extra
  }

  @inlinable public var booleanValue: Bool { self.extra != 0 }
}

/// A run of recorded events in document order, delivered together (see `StreamEventBatchingSink`).
public struct StreamEventBatch: ~Escapable {
  @usableFromInline let recordBase: UnsafePointer<StreamEventRecord>
  @usableFromInline let infoBase: UnsafePointer<NumberInfo>
  @usableFromInline let bytesBase: UnsafePointer<UInt8>
  @usableFromInline let bufferBase: UnsafePointer<UInt8>
  public let count: Int

  // A batch over caller-owned memory: what `StreamEventBatchingSink` hands its consumer, and SPI so
  // a benchmark can replay recorded events. Not API: nothing checks that the pointers agree with
  // the records.
  @_spi(Benchmarks)
  @_lifetime(borrow recordBase)
  public init(
    replaying recordBase: UnsafePointer<StreamEventRecord>,
    infoBase: UnsafePointer<NumberInfo>,
    count: Int,
    bytesBase: UnsafePointer<UInt8>,
    bufferBase: UnsafePointer<UInt8>
  ) {
    self.recordBase = recordBase
    self.infoBase = infoBase
    self.count = count
    self.bytesBase = bytesBase
    self.bufferBase = bufferBase
  }

  public var records: Span<StreamEventRecord> {
    @inlinable
    @_lifetime(borrow self)
    get {
      _overrideLifetime(
        Span(_unsafeElements: UnsafeBufferPointer(start: self.recordBase, count: self.count)),
        borrowing: self
      )
    }
  }

  // `extra` is the record's last stored property, with the record's alignment, so it is the last
  // four bytes. Not `MemoryLayout.offset(of:)`: key paths do not compile under Embedded Swift;
  // `StreamEventRecordLayoutTests` pins the two where they do.
  @usableFromInline
  static var inlineBytesOffset: Int {
    MemoryLayout<StreamEventRecord>.size &- MemoryLayout<UInt32>.size
  }

  /// The bytes the event at `index` would have carried: a key, a string, a chunk, a number.
  @inlinable
  @_lifetime(borrow self)
  public func bytes(of index: Int) -> Span<UInt8> {
    let record = self.recordBase + index
    let start: UnsafePointer<UInt8>
    switch record.pointee.source {
    case .input: start = self.bytesBase + Int(record.pointee.start)
    case .parserBuffer: start = self.bufferBase + Int(record.pointee.start)
    case .inline:
      start = UnsafeRawPointer(record).advanced(by: Self.inlineBytesOffset)
        .assumingMemoryBound(to: UInt8.self)
    }
    return _overrideLifetime(
      Span(_unsafeElements: UnsafeBufferPointer(start: start, count: Int(record.pointee.length))),
      borrowing: self
    )
  }

  /// The parsed form of the number at `index`. Meaningful for `number` records only.
  @inlinable
  public func info(of index: Int) -> NumberInfo { self.infoBase[index] }

  /// The byte offset, within the chunk being parsed, just past the event at `index`.
  @inlinable
  public func end(of index: Int) -> Int { Int(self.recordBase[index].end) }
}

extension StreamEventBatch {
  /// Replays the batch into a sink's per-token methods, stopping at the first recorded failure:
  /// the far side of a `StreamEventBatchConsumer` boundary. Returns `count` when every event was
  /// taken, or the index of the refused one. `.string` records go through
  /// ``StreamParseSink/string(_:)``, so a whole-string override is honored.
  @inlinable
  public func replay<S: StreamParseSink & ~Copyable>(into sink: inout S) -> Int {
    let records = self.records
    var index = 0
    while index < self.count {
      let record = records[index]
      switch record.kind {
      // Dispositions are discarded: the subtree was already recorded. Legal by the advisory
      // contract; a `.skip` sink routes the interior through what it kept (an ignored frame).
      case .beginObject: _ = sink.beginObject()
      case .endObject: sink.endObject()
      case .beginArray: _ = sink.beginArray()
      case .endArray: sink.endArray()
      case .key: sink.key(self.bytes(of: index))
      case .stringBegin: sink.stringBegin()
      case .stringChunk: sink.stringChunk(self.bytes(of: index))
      case .stringEnd: sink.stringEnd()
      case .string: sink.string(self.bytes(of: index))
      case .number: sink.number(self.bytes(of: index), info: self.info(of: index))
      case .boolean: sink.boolean(record.booleanValue)
      case .null: sink.null()
      }
      if sink.streamFailure != nil { return index }
      index &+= 1
    }
    return index
  }
}
