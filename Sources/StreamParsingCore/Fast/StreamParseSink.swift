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

// Spans borrow the parser's input and are invalid once the call returns.
//
// Sink methods do not throw. A check after every call sits on the hottest path in the parser,
// so a sink records its failure and the parser reads it once per chunk.
//
// Escapes are decoded to UTF-8 inside the parser and delivered as byte spans, so nothing here
// involves Unicode.Scalar or String. That keeps the Unicode data tables out of an embedded
// binary.
//
// The vocabulary is format agnostic rather than JSON specific so other parsers can drive the
// same sinks.
public protocol StreamParseSink: ~Copyable {
  mutating func beginObject()
  mutating func endObject()
  mutating func beginArray()
  mutating func endArray()

  // The parser guarantees at least `StreamParsingLayout.keyPaddingByteCount` readable bytes
  // past the end of a key span, so a generated matcher can load a whole vector without a
  // bounds check.
  mutating func key(_ bytes: Span<UInt8>)
  mutating func keyBegin()
  mutating func keyChunk(_ bytes: Span<UInt8>)
  mutating func keyEnd()

  // Every string and key span ends on a UTF-8 sequence boundary: the parser holds back a
  // trailing partial sequence and prepends it to the next chunk, so a sink can decode each
  // span independently.
  mutating func string(_ bytes: Span<UInt8>)
  mutating func stringBegin()
  mutating func stringChunk(_ bytes: Span<UInt8>)
  mutating func stringEnd()

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo)
  mutating func boolean(_ value: Bool)
  mutating func null()

  var streamFailure: StreamSinkFailure? { get }
}

extension StreamParseSink where Self: ~Copyable {
  // Overriding the collapsed forms avoids two of every three sink calls, which is worth a
  // substantial amount on token dense payloads where sink dispatch dominates.
  @inlinable
  public mutating func key(_ bytes: Span<UInt8>) {
    self.keyBegin()
    self.keyChunk(bytes)
    self.keyEnd()
  }

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
