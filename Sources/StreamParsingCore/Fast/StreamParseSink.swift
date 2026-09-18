// MARK: - NumberInfo

public struct NumberInfo: Hashable, Sendable {
  public var magnitude: UInt64
  public var exponent: Int16
  public var digitCount: UInt16
  public var flags: Flags

  public struct Flags: OptionSet, Hashable, Sendable {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
      self.rawValue = rawValue
    }

    // Computed rather than stored, so a client module's `flags.insert(.negative)` is an
    // immediate and not a call: a `public static let` in another module is reached through an
    // addressor, and `emitNumber` was making up to four of those calls per number.
    @inlinable public static var negative: Flags { Flags(rawValue: 1 << 0) }
    @inlinable public static var fraction: Flags { Flags(rawValue: 1 << 1) }
    @inlinable public static var exponent: Flags { Flags(rawValue: 1 << 2) }
    @inlinable public static var overflowed: Flags { Flags(rawValue: 1 << 3) }
  }

  public init(
    magnitude: UInt64 = 0,
    exponent: Int16 = 0,
    digitCount: UInt16 = 0,
    flags: Flags = []
  ) {
    self.magnitude = magnitude
    self.exponent = exponent
    self.digitCount = digitCount
    self.flags = flags
  }
}

// MARK: - StreamApplyResult

// What a destination did with a token; non-exhaustive, so a rejection kind can be added later. The
// raw values are load-bearing: `applied` must be zero and the minimum, since the string path folds
// chunk results with `max` rather than a branch (measured: a branch per chunk cost Twitter
// discarding 8.7%). A new case takes the next integer.
@nonexhaustive
public enum StreamApplyResult: UInt8, Hashable, Sendable {
  /// The destination took the token.
  case applied = 0
  /// The destination cannot hold this kind of token at all.
  case unsupported = 1
  /// The destination holds this kind of token but has no room left for it.
  case capacityExceeded = 2
  /// A completed source value was rejected by its conversion strategy.
  case conversionFailed = 3
}

// MARK: - StreamSinkFailure

public struct StreamSinkFailure: Error, Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    case typeMismatch
    case conversionFailed
    case depthExceeded
    /// Bounded storage overflowed: an inline string past its capacity, or a fixed-size array
    /// given more elements than it declares.
    case capacityExceeded
  }

  public var reason: Reason

  public init(reason: Reason) {
    self.reason = reason
  }
}

// MARK: - StreamEventBatch

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

  @_lifetime(borrow recordBase)
  @usableFromInline
  init(
    recordBase: UnsafePointer<StreamEventRecord>, infoBase: UnsafePointer<NumberInfo>,
    count: Int, bytesBase: UnsafePointer<UInt8>, bufferBase: UnsafePointer<UInt8>
  ) {
    self.recordBase = recordBase
    self.infoBase = infoBase
    self.count = count
    self.bytesBase = bytesBase
    self.bufferBase = bufferBase
  }

  // A batch over caller-owned memory, for the benchmark suite's replay rows
  // (`PartialSinkReplayBenchmarks.swift`). Not API: nothing checks that the pointers agree with the
  // records.
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

// MARK: - StreamContainerDisposition

/// A sink's answer to a container opening: how it wants the subtree delivered.
///
/// Returned from ``StreamParseSink/beginObject()`` and ``StreamParseSink/beginArray()``. The
/// answer is *advisory*: a deliverer that cannot skip (the batching adapter's replay) delivers the
/// interior anyway, so a sink answering ``skip`` must still handle it. When the parser honors it,
/// the interior runs at structural-scan speed with no sink calls. Non-exhaustive, so a
/// byte-delivering case can be added later.
@nonexhaustive
public enum StreamContainerDisposition: UInt8, Hashable, Sendable {
  /// Parse and deliver the subtree token by token: the normal path.
  case stream = 0
  /// The sink has no use for the subtree's interior: the parser skips to the matching close and
  /// delivers only the matching `endObject`/`endArray` call.
  ///
  /// A skipped interior is validated *structurally*: brackets match by kind, strings terminate
  /// (control bytes and invalid UTF-8 still rejected) and the depth cap holds, but number grammar,
  /// escape selectors and comma/colon placement are not checked, so a malformed interior a
  /// streaming sink would reject can pass under a skipping one.
  case skip = 1
}

// MARK: - StreamParseSink

/// Receives the parser's tokens, one call per token at the lex points (inlined into the parse
/// loop when specialized). Every span borrows the parser's input or buffer, is invalid once the
/// call returns, has no readable padding, and ends on a UTF-8 boundary; a key is always whole, and
/// a number is one call carrying the token and its parsed info.
///
/// The container opens return an advisory ``StreamContainerDisposition``. Nothing else throws or
/// returns: a sink records its failure, which the parser polls through ``streamFailure`` at token
/// boundaries and reports at the provoking token. Once recorded, later tokens must not clear it.
public protocol StreamParseSink: ~Copyable {

  // Structure. The disposition is deliberately not defaulted: a defaulted returning requirement
  // silently shadows a conformer's `Void` implementation. Answer `.stream` when in doubt; after a
  // `.skip` the interior may still arrive, but the matching end call always does.
  mutating func beginObject() -> StreamContainerDisposition
  mutating func endObject()
  mutating func beginArray() -> StreamContainerDisposition
  mutating func endArray()

  /// An object member's key, always whole: unescaped, validated UTF-8.
  mutating func key(_ bytes: Span<UInt8>)

  /// The fallback string form: a value cut by a chunk boundary or carrying escapes arrives as
  /// `stringBegin`, chunks, `stringEnd`. Mandatory for correctness on chunked input.
  ///
  /// Chunk boundaries carry no meaning. Content before a value's first escape is a zero-copy
  /// borrow of the input; from the first escape on, decoded escapes and the runs between them are
  /// coalesced and delivered per buffer-full (a run at least a buffer long still goes in place, and
  /// an escape straddling a parse call's end arrives as its own chunk).
  mutating func stringBegin()
  mutating func stringChunk(_ bytes: Span<UInt8>)
  mutating func stringEnd()

  /// The common string: complete in the chunk and escape-free, a zero-copy borrow of the input
  /// delivered as one call. Defaulted through the chunked triple, so a minimal sink implements
  /// nothing extra and an optimized one overrides exactly the hot form.
  mutating func string(_ bytes: Span<UInt8>)

  /// One call per number: the whole token and its parsed form.
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo)

  mutating func boolean(_ value: Bool)
  mutating func null()

  /// Called when memory the sink's spans borrowed is about to become invalid: at the end of each
  /// parse call and at finish. A sink that deferred work referencing borrowed bytes must complete
  /// it now; when and how much to buffer stays its business. Defaulted to a no-op.
  mutating func commit()

  var streamFailure: StreamSinkFailure? { get }
}

extension StreamParseSink where Self: ~Copyable {
  /// A whole string is the chunked triple with the middle skipped when empty. `stringBegin`
  /// settles whether the destination accepts strings at all, so the failure check between it
  /// and the chunk keeps a refusal at the opening quote from feeding bytes anyway.
  @inlinable
  public mutating func string(_ bytes: Span<UInt8>) {
    self.stringBegin()
    if self.streamFailure != nil { return }
    if bytes.count > 0 { self.stringChunk(bytes) }
    self.stringEnd()
  }

  @inlinable
  public mutating func commit() {}
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
