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

    public static let negative = Flags(rawValue: 1 << 0)
    public static let fraction = Flags(rawValue: 1 << 1)
    public static let exponent = Flags(rawValue: 1 << 2)
    public static let overflowed = Flags(rawValue: 1 << 3)
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
  // A key is the one token the parser buffers rather than passing through: `consumeStringRun`
  // copies it so it is contiguous across chunks, and `emitBufferedKey` zeroes
  // `StreamParsingLayout.keyPaddingByteCount` bytes past its end so a generated matcher can load
  // a whole vector without a bounds check. A key delivered in pieces can offer neither, so the
  // chunked trio this used to declare alongside `key(_:)` was a promise no parser could keep and
  // no sink could honour: `PartialSink` answered it by routing each fragment separately, which
  // matched on the last fragment alone and, for a dictionary, made one entry per piece.
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

// MARK: - Layout guarantees

public enum StreamParsingLayout {
  public static let keyPaddingByteCount = 16
}
