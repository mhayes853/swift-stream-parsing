// Value conversion.
//
// Three narrow protocols rather than one wide one, so conforming a type is trivial: `Data` only
// needs an append, `Decimal` only needs an initializer. They are bridged into generated code by
// overload pairs, because a macro sees only the syntax of a property's type and cannot know
// whether `String` accepts string content or `Int` accepts numeric content. The constrained
// overload does the work, the unconstrained one silently does nothing, and Swift ranks the
// constrained one higher. Dead combinations optimize away entirely.

// MARK: - Protocols

/// A value built from string content.
public protocol StreamStringConvertible {
  static func streamInitialValue() -> Self

  /// Appends decoded UTF-8. Called once for a complete value, or repeatedly as one streams in.
  mutating func streamAppend(utf8 bytes: Span<UInt8>)

  /// Called before the first append when the parser knows the final byte count.
  ///
  /// Lets a `String` land in its inline small-string form without allocating.
  mutating func streamReserve(utf8ByteCount: Int)
}

extension StreamStringConvertible {
  public mutating func streamReserve(utf8ByteCount: Int) {}
}

/// A value built from a numeric token.
public protocol StreamNumberConvertible {
  init?(streamParsing bytes: Span<UInt8>, info: NumberInfo)
}

/// A value built from a boolean literal.
public protocol StreamBooleanConvertible {
  init(streamParsingBoolean value: Bool)
}

/// A value that can represent a null literal.
public protocol StreamNullable {
  static func streamNullValue() -> Self
}

// MARK: - Bridging shims

@inlinable
@inline(__always)
public func streamApply<T: StreamStringConvertible>(_ value: inout T, utf8 bytes: Span<UInt8>) {
  value.streamAppend(utf8: bytes)
}

@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, utf8 bytes: Span<UInt8>) {}

@inlinable
@inline(__always)
public func streamApply<T: StreamNumberConvertible>(
  _ value: inout T, bytes: Span<UInt8>, info: NumberInfo
) {
  if let parsed = T(streamParsing: bytes, info: info) { value = parsed }
}

@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, bytes: Span<UInt8>, info: NumberInfo) {}

@inlinable
@inline(__always)
public func streamApply<T: StreamBooleanConvertible>(_ value: inout T, boolean: Bool) {
  value = T(streamParsingBoolean: boolean)
}

@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, boolean: Bool) {}

@inlinable
@inline(__always)
public func streamApplyNull<T: StreamNullable>(_ value: inout T) {
  value = T.streamNullValue()
}

@inlinable
@inline(__always)
public func streamApplyNull<T>(_ value: inout T) {}

// MARK: - Digit parsing

/// Builds a fixed width integer from a numeric token.
///
/// Uses the magnitude the parser accumulated while scanning when it is exact, which covers
/// every integer of nineteen digits or fewer, and re-scans the span otherwise.
@inlinable
public func streamParseInteger<T: FixedWidthInteger>(
  _ bytes: Span<UInt8>, info: NumberInfo, as type: T.Type = T.self
) -> T? {
  guard !info.flags.contains(.fraction), !info.flags.contains(.exponent) else { return nil }

  if !info.flags.contains(.overflowed) {
    if info.flags.contains(.negative) {
      guard T.isSigned, info.magnitude <= UInt64(T.max.magnitude) &+ 1 else { return nil }
      if info.magnitude == UInt64(T.max.magnitude) &+ 1 { return T.min }
      return T(exactly: info.magnitude).map { 0 &- $0 }
    }
    return T(exactly: info.magnitude)
  }

  // The accumulated magnitude wrapped, so the token has more digits than a `UInt64` holds and
  // cannot fit any narrower type either.
  return nil
}

/// Builds a floating point value from a numeric token.
///
/// Always re-scans the span, because correct rounding needs the digits and the exponent rather
/// than a truncated significand.
@inlinable
public func streamParseFloatingPoint<T: BinaryFloatingPoint>(
  _ bytes: Span<UInt8>, info: NumberInfo, as type: T.Type = T.self
) -> T? where T: LosslessStringConvertible {
  // Numeric tokens are ASCII by construction, so a scalar-wise build is exact here.
  var text = ""
  text.reserveCapacity(bytes.count)
  for i in 0..<bytes.count {
    text.unicodeScalars.append(Unicode.Scalar(bytes[i]))
  }
  return T(text)
}

// MARK: - Standard library conformances

extension String: StreamStringConvertible {
  public static func streamInitialValue() -> Self { "" }

  public mutating func streamAppend(utf8 bytes: Span<UInt8>) {
    bytes.withUnsafeBufferPointer { buffer in
      self += String(decoding: buffer, as: UTF8.self)
    }
  }

  public mutating func streamReserve(utf8ByteCount: Int) {
    self.reserveCapacity(utf8ByteCount)
  }
}

extension Bool: StreamBooleanConvertible {
  public init(streamParsingBoolean value: Bool) { self = value }
}

extension Optional: StreamNullable {
  public static func streamNullValue() -> Self { nil }
}

extension Int: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: Int = streamParseInteger(bytes, info: info) else { return nil }
    self = value
  }
}

extension Int8: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: Int8 = streamParseInteger(bytes, info: info) else { return nil }
    self = value
  }
}

extension Int16: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: Int16 = streamParseInteger(bytes, info: info) else { return nil }
    self = value
  }
}

extension Int32: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: Int32 = streamParseInteger(bytes, info: info) else { return nil }
    self = value
  }
}

extension Int64: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: Int64 = streamParseInteger(bytes, info: info) else { return nil }
    self = value
  }
}

extension UInt: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: UInt = streamParseInteger(bytes, info: info) else { return nil }
    self = value
  }
}

extension UInt8: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: UInt8 = streamParseInteger(bytes, info: info) else { return nil }
    self = value
  }
}

extension UInt16: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: UInt16 = streamParseInteger(bytes, info: info) else { return nil }
    self = value
  }
}

extension UInt32: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: UInt32 = streamParseInteger(bytes, info: info) else { return nil }
    self = value
  }
}

extension UInt64: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: UInt64 = streamParseInteger(bytes, info: info) else { return nil }
    self = value
  }
}

extension Double: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    if info.isExactMagnitude, let exact = Double(exactly: info.magnitude) {
      self = info.flags.contains(.negative) ? -exact : exact
      return
    }
    guard let value: Double = streamParseFloatingPoint(bytes, info: info) else { return nil }
    self = value
  }
}

extension Float: StreamNumberConvertible {
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value: Float = streamParseFloatingPoint(bytes, info: info) else { return nil }
    self = value
  }
}
