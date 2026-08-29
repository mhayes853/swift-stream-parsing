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

// MARK: - StreamParseSink

/// Receives the parser's events, a batch at a time. The batch borrows the parser's input and
/// buffer and is invalid once the call returns; a key, string chunk or number is readable only
/// within its span's count — there is no padding behind it. Every string and key span ends on
/// a UTF-8 sequence boundary; a key is always whole; a number is exactly one event carrying the
/// whole token and its parsed info.
///
/// The method does not throw: a check after every event sits on the hottest path, so a sink
/// records its failure, returns the index of the event it refused, and the parser reads the
/// failure once per batch and reports it at that event.
public protocol StreamParseSink: ~Copyable {
  /// Consumes events in order and returns how many were taken: `batch.count` when all were, or
  /// the index of the event the sink refused after recording ``streamFailure``.
  mutating func events(_ batch: borrowing StreamEventBatch) -> Int

  var streamFailure: StreamSinkFailure? { get }
}
