// MARK: - NumberInfo

/// The payload of a numeric token.
///
/// The parser accumulates ``magnitude`` while it scans for the token boundary, using wrapping
/// arithmetic and a digit count check rather than per digit overflow checks. Consumers wanting
/// a fixed width integer read it directly; consumers wanting `Double`, `Decimal` or a 128 bit
/// type re-scan the accompanying byte span, which they need for correct rounding anyway.
public struct NumberInfo: Hashable, Sendable {
  /// The accumulated significand, valid unless ``Flags/overflowed`` is set.
  public var magnitude: UInt64

  /// The number of digits seen, ignoring sign, decimal point and exponent.
  public var digitCount: UInt16

  public var flags: Flags

  public struct Flags: OptionSet, Hashable, Sendable {
    public var rawValue: UInt16

    public init(rawValue: UInt16) {
      self.rawValue = rawValue
    }

    /// The token began with a minus sign. Exponent signs do not set this.
    public static let negative = Flags(rawValue: 1 << 0)
    public static let fraction = Flags(rawValue: 1 << 1)
    public static let exponent = Flags(rawValue: 1 << 2)

    /// ``NumberInfo/magnitude`` is not exact and the byte span must be re-scanned.
    public static let overflowed = Flags(rawValue: 1 << 3)
  }

  public init(magnitude: UInt64 = 0, digitCount: UInt16 = 0, flags: Flags = []) {
    self.magnitude = magnitude
    self.digitCount = digitCount
    self.flags = flags
  }

  /// Whether ``magnitude`` can be trusted without re-scanning the span.
  @inlinable
  public var isExactMagnitude: Bool {
    !self.flags.contains(.overflowed)
      && !self.flags.contains(.fraction)
      && !self.flags.contains(.exponent)
  }
}

// MARK: - StreamSinkFailure

/// Reported by a sink that cannot accept a token.
///
/// Sink methods do not throw. Making them throwing costs a check after every call on the
/// hottest path in the parser, so a sink records its failure and the parser reads it once per
/// chunk instead.
public struct StreamSinkFailure: Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    /// A token arrived whose type the destination cannot represent.
    case typeMismatch
    /// The destination ran out of room.
    case capacityExceeded
    /// Nesting exceeded what the destination can hold.
    case depthExceeded
  }

  public var reason: Reason

  public init(reason: Reason) {
    self.reason = reason
  }
}

// MARK: - StreamParseSink

/// Receives parse events from a ``StreamParser``.
///
/// Every span borrows the parser's input and is invalid once the call returns. A sink that
/// wants to keep bytes must copy them.
///
/// Escape sequences are decoded to UTF-8 inside the parser and delivered as byte spans, so no
/// part of this protocol involves `Unicode.Scalar` or `String`. That is what keeps the Unicode
/// data tables out of an embedded binary.
///
/// The vocabulary is deliberately format agnostic rather than JSON specific, so other parsers
/// can drive the same sinks.
public protocol StreamParseSink: ~Copyable {
  mutating func beginObject()
  mutating func endObject()
  mutating func beginArray()
  mutating func endArray()

  /// A key delivered in one piece.
  ///
  /// The parser guarantees at least ``StreamParsingLayout/keyPaddingByteCount`` readable bytes
  /// past the end of this span, so a matcher can load a whole word or vector without a bounds
  /// check.
  mutating func key(_ bytes: Span<UInt8>)
  mutating func keyBegin()
  mutating func keyChunk(_ bytes: Span<UInt8>)
  mutating func keyEnd()

  /// A string value complete within one chunk and free of escape sequences.
  ///
  /// Every string and key span ends on a UTF-8 sequence boundary. The parser holds back a
  /// trailing partial sequence and prepends it to the next chunk, so a sink can decode each
  /// span independently without tracking continuation bytes itself.
  mutating func string(_ bytes: Span<UInt8>)
  mutating func stringBegin()
  mutating func stringChunk(_ bytes: Span<UInt8>)
  mutating func stringEnd()

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo)
  mutating func boolean(_ value: Bool)
  mutating func null()

  /// Non-nil once the sink has rejected a token.
  var streamFailure: StreamSinkFailure? { get }
}

extension StreamParseSink where Self: ~Copyable {
  /// Routes the collapsed form through the incremental one.
  ///
  /// Overriding ``key(_:)`` and ``string(_:)`` avoids two of every three sink calls, which is
  /// worth a substantial amount on token dense payloads where sink dispatch dominates.
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

/// Invariants the parser upholds for its sinks.
public enum StreamParsingLayout {
  /// Readable bytes guaranteed past the end of a key span.
  ///
  /// A generated key matcher loads a whole 16 byte vector regardless of the key's length, which
  /// would read past the input buffer for a key ending near the end of a chunk. The parser
  /// copies such keys into its own buffer so that the matcher never needs a bounds check.
  public static let keyPaddingByteCount = 16
}
