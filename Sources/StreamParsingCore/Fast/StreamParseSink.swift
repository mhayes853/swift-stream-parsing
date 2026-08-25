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

// MARK: - StreamSinkFailure

public struct StreamSinkFailure: Error, Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    case typeMismatch
    case depthExceeded
  }

  public var reason: Reason

  public init(reason: Reason) {
    self.reason = reason
  }
}

// MARK: - StreamNumberBatch

/// A run of whole numbers from one contiguous region of the input, in document order, delivered
/// together. Borrowed for the call, like every span a sink sees.
///
/// The parser produces batches only where it already knows a run is nothing but numbers — an
/// array of numbers walked by the windowed path — so a sink that never overrides
/// ``StreamParseSink/numbers(_:)`` sees exactly the ``StreamParseSink/number(_:info:)`` events it
/// always has. A sink that does override it gets one call per up to 64 numbers, which is what
/// lets a destination array reserve once, convert in a loop, and skip the per-event routing.
public struct StreamNumberBatch: ~Escapable {
  @usableFromInline let infoBase: UnsafePointer<NumberInfo>
  // (offset, length) pairs: half the store and reload traffic of a `Range<Int>` per number,
  // on a path where that traffic measured.
  @usableFromInline let tokenBase: UnsafePointer<UInt32>
  @usableFromInline let bytesBase: UnsafePointer<UInt8>
  @usableFromInline let byteCount: Int
  /// The number of numbers in the batch.
  public let count: Int

  @_lifetime(borrow infoBase)
  @usableFromInline
  init(
    infoBase: UnsafePointer<NumberInfo>,
    tokenBase: UnsafePointer<UInt32>,
    count: Int,
    bytesBase: UnsafePointer<UInt8>,
    byteCount: Int
  ) {
    self.infoBase = infoBase
    self.tokenBase = tokenBase
    self.count = count
    self.bytesBase = bytesBase
    self.byteCount = byteCount
  }

  /// The parsed form of every number, in order.
  public var infos: Span<NumberInfo> {
    @_lifetime(borrow self)
    get {
      _overrideLifetime(
        Span(_unsafeElements: UnsafeBufferPointer(start: self.infoBase, count: self.count)),
        borrowing: self
      )
    }
  }

  /// The bytes of the number at `index`, as ``StreamParseSink/number(_:info:)`` would deliver them.
  @_lifetime(borrow self)
  public func token(at index: Int) -> Span<UInt8> {
    let start = Int(self.tokenBase[2 &* index])
    let length = Int(self.tokenBase[2 &* index &+ 1])
    return _overrideLifetime(
      Span(_unsafeElements: UnsafeBufferPointer(start: self.bytesBase + start, count: length)),
      borrowing: self
    )
  }

  /// The byte offset, within the chunk being parsed, just past the number at `index`.
  @inlinable
  public func end(of index: Int) -> Int {
    Int(self.tokenBase[2 &* index]) &+ Int(self.tokenBase[2 &* index &+ 1])
  }
}

// MARK: - StreamParseSink

// Spans borrow the parser's input and are invalid once the call returns. Methods do not throw:
// a check after every call sits on the hottest path, so a sink records its failure and the
// parser reads it once per chunk.
public protocol StreamParseSink: ~Copyable {
  mutating func beginObject()
  mutating func endObject()
  mutating func beginArray()
  mutating func endArray()

  // Whole, always, and unlike a string value there is no chunked form to fall back to.
  //
  // A key that arrives inside one chunk is a span into the parser's input; one the chunk cuts
  // is reassembled in the parser's buffer first. Either way the span is borrowed, valid only
  // for the call, and readable only within its count — there is no padding behind it. A matcher
  // that wants whole words reads them through `paddedWord`, which is bounded. A key delivered
  // in pieces could offer none of this, so the chunked trio this used to declare alongside
  // `key(_:)` was a promise no parser could keep and no sink could honour: `PartialSink`
  // answered it by routing each fragment separately, which matched on the last fragment alone
  // and, for a dictionary, made one entry per piece.
  mutating func key(_ bytes: Span<UInt8>)

  // Every string and key span ends on a UTF-8 sequence boundary.
  mutating func stringBegin()
  mutating func stringChunk(_ bytes: Span<UInt8>)
  mutating func stringEnd()

  // Exactly one event per number token, carrying the whole token's bytes and its parsed info.
  // A numeric prefix is not a value prefix — `1234` passes through 1, 12 and 123 on the way,
  // each a different number by an order of magnitude — so nothing provisional is reported.
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo)
  mutating func boolean(_ value: Bool)
  mutating func null()

  /// A run of whole numbers, delivered together; see ``StreamNumberBatch``.
  ///
  /// Returns how many of the batch were taken. A sink that rejects a number records its failure
  /// and returns that number's index, so the parser reports the rejection at the same offset it
  /// would have for a single ``number(_:info:)`` event — the byte after that token. Returning
  /// fewer than `batch.count` without recording a failure is a contract violation. The default
  /// delivers each number through ``number(_:info:)`` and stops at the first failure; a sink
  /// that consumes numbers in volume should override it, since a run of numbers the windowed
  /// path walks arrives this way and nowhere else.
  mutating func numbers(_ batch: borrowing StreamNumberBatch) -> Int

  var streamFailure: StreamSinkFailure? { get }
}

extension StreamParseSink where Self: ~Copyable {
  @inlinable
  public mutating func numbers(_ batch: borrowing StreamNumberBatch) -> Int {
    let infos = batch.infos
    var index = 0
    while index < batch.count {
      self.number(batch.token(at: index), info: infos[index])
      if self.streamFailure != nil { return index }
      index &+= 1
    }
    return index
  }
}
