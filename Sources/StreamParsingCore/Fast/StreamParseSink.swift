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

// What a destination did with a token.
//
// A `Bool` carried this until bounded storage arrived: an inline string that is full has not
// declined the *kind* of token, it has run out of room for it, and reporting the two as one
// value made a capacity failure indistinguishable from a schema mismatch. Non-exhaustive so a
// later kind of rejection -- a number outside a field's range is the obvious candidate -- can be
// added without breaking clients that switch over this.
//
// Still one byte in a register, exactly as the `Bool` was. The raw values are load-bearing rather
// than decorative: `applied` is zero so a check against it is a branch on zero, and the string
// path folds a chunk's result into the value it already holds with `max` rather than a branch --
// measured, because branching on this per chunk cost 8.7% of `Real Twitter - bulk discarding`.
// Any ordering where `applied` is the minimum keeps that fold correct; a case added later can
// take the next integer.
@nonexhaustive
public enum StreamApplyResult: UInt8, Hashable, Sendable {
  /// The destination took the token.
  case applied = 0
  /// The destination cannot hold this kind of token at all.
  case unsupported = 1
  /// The destination holds this kind of token but has no room left for it.
  case capacityExceeded = 2
}

// MARK: - StreamSinkFailure

public struct StreamSinkFailure: Error, Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    case typeMismatch
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
    /// A whole string value, complete in the chunk and free of escapes: what the byte fed path
    /// delivers as `stringBegin`, one `stringChunk` (omitted when empty) and `stringEnd`. One
    /// record where those are three. A sink that rejects it is taken to have rejected it at
    /// `stringBegin`, and the parser reports the rejection at the byte after the opening quote.
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

/// A run of events, in document order, delivered together: a chunk's worth on the byte fed and
/// small-chunk path, a window's worth on the windowed path. The sink sees them with lookahead,
/// and can take a run — numbers into an array, members into an object — in one pass.
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

  // A batch over memory the caller owns rather than the parser's scratch. For the benchmark
  // suite's replay rows, which record the batches a parse delivered and hand them back to a sink
  // with no parser in the loop (`Benchmarks/.../PartialSinkReplayBenchmarks.swift`). Not API:
  // nothing checks that the pointers agree with the records, which is the parser's job.
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

  // `extra` is the record's last stored property and its alignment is the record's, so the last
  // four bytes of a record are exactly `extra` and there is no trailing padding to skip.
  // Computed this way rather than through `MemoryLayout.offset(of:)` because a key path does not
  // compile under Embedded Swift; `StreamEventRecordLayoutTests` pins the two against each other
  // where key paths are available.
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
/// answer is *advisory*: a deliverer that cannot skip — the batching adapter's replay, which has
/// already recorded the subtree — delivers the interior anyway, so a sink answering ``skip``
/// must still be correct receiving it (`PartialSink` keeps its ignored frame for exactly this).
/// What the answer buys when the parser *can* honor it: the subtree's interior runs at
/// structural-scan speed — no key matching, no number parse, no escape decode, no sink calls.
///
/// Non-exhaustive so a byte-delivering case (`wholeValue`, handing the subtree's raw bytes to
/// the sink at the close) can be added without breaking clients that switch over this.
@nonexhaustive
public enum StreamContainerDisposition: UInt8, Hashable, Sendable {
  /// Parse and deliver the subtree token by token: the normal path.
  case stream = 0
  /// The sink has no use for the subtree's interior. The parser skips to the matching close
  /// and delivers only the matching `endObject`/`endArray` call — nothing in between.
  ///
  /// A skipped interior is validated *structurally*, not tokenwise: brackets must match by
  /// kind, strings must terminate (with control bytes still rejected and UTF-8 still
  /// validated), and the depth cap still holds — but number grammar, escape selectors and
  /// comma/colon placement inside it are not checked. A malformed interior a streaming sink
  /// would have rejected can therefore pass under a skipping one.
  case skip = 1
}

// MARK: - StreamParseSink

/// Receives the parser's tokens.
///
/// The per-token methods are the primary interface: the parser calls them at the lex points,
/// and a sink compiled in the same specialization domain has them inlined into the parse loop —
/// there is no transport between lexing a token and storing it. Every span borrows the parser's
/// input or buffer and is invalid once the call returns; a key, string chunk or number is
/// readable only within its span's count — there is no padding behind it. Every string and key
/// span ends on a UTF-8 sequence boundary; a key is always whole (the parser reassembles one a
/// chunk boundary or escape cut); a number is exactly one call carrying the whole token and its
/// parsed info, so no sink re-lexes digits.
///
/// The two container opens return a ``StreamContainerDisposition``: a sink with no use for a
/// subtree's interior answers ``StreamContainerDisposition/skip`` and the parser scans past it
/// at structural speed, delivering only the matching close. The answer is advisory — see the
/// disposition's own documentation for the contract.
///
/// No other method throws or returns a result: a check after every token sits on the hottest path and
/// pins the callee's tail calls (measured on the string chunk path), so a sink records its
/// failure and the parser polls ``streamFailure`` at token boundaries, reporting the failure at
/// the token that provoked it. The failure is sticky: once recorded, later tokens must not
/// clear it.
public protocol StreamParseSink: ~Copyable {

  // Structure. The parser owns grammar and depth; these observe — and answer. The returned
  // disposition is deliberately not defaulted: a defaulted returning requirement silently
  // shadows a conformer's `Void` implementation (the classic near-miss), and a sink author
  // should decide, per container, whether the interior matters. Answer `.stream` when in doubt.
  // The answer is advisory (see `StreamContainerDisposition`): a `.skip` answer may still be
  // followed by the interior, but the matching end call always arrives.
  mutating func beginObject() -> StreamContainerDisposition
  mutating func endObject()
  mutating func beginArray() -> StreamContainerDisposition
  mutating func endArray()

  /// An object member's key, always whole: unescaped, validated UTF-8.
  mutating func key(_ bytes: Span<UInt8>)

  /// The fallback string form: a value cut by a chunk boundary or carrying escapes arrives as
  /// `stringBegin`, chunks, `stringEnd`. Rare per document, mandatory for correctness — a sink
  /// that ignores these is wrong on chunked input.
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

  /// Called when memory the sink's spans borrowed is about to become invalid: at the end of
  /// each parse call and at finish. A sink that deferred work referencing borrowed bytes — a
  /// batching adapter holding record offsets into the input — must complete it now. The parser
  /// signals lifetimes only; when and how much to buffer stays the sink's business. Defaulted
  /// to a no-op.
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
  /// the receiving end of the batch transport, for a `StreamEventBatchConsumer` that drives an
  /// ordinary sink on the far side of whatever boundary the batching crossed. Returns how many
  /// events were taken — `count` when all were, or the index of the refused event. `.string`
  /// records route through ``StreamParseSink/string(_:)`` so a whole-string override is honored
  /// on this path too.
  @inlinable
  public func replay<S: StreamParseSink & ~Copyable>(into sink: inout S) -> Int {
    let records = self.records
    var index = 0
    while index < self.count {
      let record = records[index]
      switch record.kind {
      // Dispositions are discarded: the subtree was already recorded, so there is nothing left
      // to skip. The advisory contract is what makes that legal — a sink that answered `.skip`
      // routes the interior through whatever it kept standing (PartialSink's ignored frame).
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
