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

  public var isExactInteger: Bool {
    !self.flags.contains(.overflowed) && self.exponent == 0
  }
}

// MARK: - StreamSinkFailure

public struct StreamSinkFailure: Error, Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    case typeMismatch
    case capacityExceeded
    case depthExceeded
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
  mutating func string(_ bytes: Span<UInt8>)
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

extension StreamParseSink where Self: ~Copyable {
  // Overriding the collapsed form avoids two of every three sink calls.
  @inlinable
  public mutating func string(_ bytes: Span<UInt8>) {
    self.stringBegin()
    self.stringChunk(bytes)
    self.stringEnd()
  }
}
