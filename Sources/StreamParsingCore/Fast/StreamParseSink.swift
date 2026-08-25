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

  var streamFailure: StreamSinkFailure? { get }
}
