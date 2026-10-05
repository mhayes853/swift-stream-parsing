// MARK: - Protocols

/// A type with a value the parser can start from.
///
/// Anything a container can hold, since an element has to exist before it can be written into.
public protocol StreamInitializable: SendableMetatype {
  /// The value a parse begins with, before any token has been written into it.
  static func streamInitialValue() -> Self
}

/// A destination for JSON string tokens.
///
/// The parser delivers a string as one or more spans of UTF-8, in order, each ending on a scalar
/// boundary; where one ends carries no meaning. A conformance accumulates them.
public protocol StreamStringConvertible: StreamInitializable {
  // Whether the bytes were taken. Unbounded storage answers `.applied` (folded on specialization);
  // bounded storage answers `.capacityExceeded` without taking any bytes, so a value holds exactly
  // what it accumulated up to the last append that fit.
  @discardableResult
  mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult

  // How a schema recognizes inline storage it cannot name: a static requirement, not a metatype
  // cast (`_streamStringSchema` cannot spell `StreamInlineString<capacity>`, and an existential
  // cast would not survive Embedded). Zero means not inline; non-zero promises (checked in
  // `_streamStringSchema`) `_streamInlineByteOffset` header bytes, then that many UTF-8 bytes.
  static var _streamInlineCapacity: Int { get }
  static var _streamInlineByteOffset: Int { get }
}

extension StreamStringConvertible {
  @inlinable
  public static var _streamInlineCapacity: Int { 0 }
  @inlinable
  public static var _streamInlineByteOffset: Int { 0 }
}

/// A destination for JSON number tokens.
public protocol StreamNumberConvertible: SendableMetatype {
  /// Converts a number token, or returns `nil` to reject it, which the parser reports as a type
  /// mismatch.
  ///
  /// - Parameters:
  ///   - bytes: The token as written.
  ///   - info: The same token, lexed: its digits, scale and sign. See ``NumberInfo``, and check
  ///     `info.flags` for `.overflowed` before reading `info.magnitude`.
  init?(streamParsing bytes: Span<UInt8>, info: NumberInfo)
}

/// A destination for the JSON literals `true` and `false`.
public protocol StreamBooleanConvertible: SendableMetatype {
  /// Creates the value for a `true` or `false` token.
  init(streamParsingBoolean value: Bool)
}

/// A destination that has a value of its own for JSON `null`.
///
/// A type without one is cleared when its member is optional, and rejects `null` otherwise.
public protocol StreamNullable: SendableMetatype {
  /// The value a `null` token writes.
  static func streamNullValue() -> Self
}

// MARK: - Integers

extension FixedWidthInteger {
  // A token carrying a fraction or an exponent part is rejected rather than scaled, even when it
  // scales by nothing: `1e0` is written as a float, as `1.0` is. Inlinable so a specialised caller
  // gets a specialised conversion: through the protocol witness alone it paid a metadata lookup
  // per number, Mesh at half speed.
  @inlinable
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    // One mask test on the raw bits. The parser only sets a nonzero `exponent` alongside one of
    // the two flags; the compare keeps a hand-built `NumberInfo` honest.
    let notInteger = NumberInfo.Flags.fraction.rawValue | NumberInfo.Flags.exponent.rawValue
    guard info.flags.rawValue & notInteger == 0, info.exponent == 0 else { return nil }

    // The accumulator flags anything it could not hold in a UInt64, which includes values that
    // do fit the destination: UInt64.max is twenty digits. Walking the token settles it rather
    // than rejecting a number the type can represent.
    if info.flags.contains(.overflowed) {
      guard let rescanned = _streamRescanInteger(bytes, as: Self.self) else { return nil }
      self = rescanned
      return
    }

    if info.flags.contains(.negative) {
      // `-0` is zero, which an unsigned type holds; any other negative is out of its range.
      guard Self.isSigned else {
        guard info.magnitude == 0 else { return nil }
        self = 0
        return
      }
      // Integer-to-integer `init?(exactly:)` folds to a range compare, so the objection the
      // floating-point path below raises against `init(exactly:)` does not apply here. The bound is
      // in `Self.Magnitude`, not `UInt64`: widening the other way traps past 64 bits.
      guard let magnitude = Self.Magnitude(exactly: info.magnitude),
        magnitude <= Self.min.magnitude
      else { return nil }
      if magnitude == Self.min.magnitude {
        self = Self.min
        return
      }
      self = 0 &- Self(magnitude)
      return
    }

    guard let value = Self(exactly: info.magnitude) else { return nil }
    self = value
  }
}

// MARK: - Floating point

// Preserve the existing convenience initializer for BinaryFloatingPoint types
// that have not opted into StreamFastFloatConvertible. Protocol conformers use
// the more constrained default, whose conversion step calls their requirement.
extension BinaryFloatingPoint where Self: LosslessStringConvertible {
  @inlinable
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = streamParseFloatingPoint(bytes, info: info, as: Self.self, convertDecimal: {
      streamEiselLemire(magnitude: $0, exponent: $1, negative: $2, as: Self.self)
    }) else { return nil }
    self = value
  }
}

// Inlined into both initializer defaults: the closure is a static conversion
// choice, not a stored callback or a runtime conformance cast. A concrete caller
// must contain Clinger + its chosen kernel + the cold String fallback, with no
// closure allocation, metadata lookup, or witness dispatch in the numeric path.
@inlinable
@inline(__always)
func streamParseFloatingPoint<T: BinaryFloatingPoint & LosslessStringConvertible>(
  _ bytes: Span<UInt8>, info: NumberInfo, as type: T.Type,
  convertDecimal: (UInt64, Int, Bool) -> T?
) -> T? {
  let flags = info.flags.rawValue
  guard flags & NumberInfo.Flags.overflowed.rawValue == 0 else {
    // More than nineteen digits: magnitude may have wrapped and must not be used.
    return streamParseFloatingPointFallback(bytes, as: T.self)
  }

  let magnitude = info.magnitude
  let exponent = Int(info.exponent)
  let negative = flags & NumberInfo.Flags.negative.rawValue != 0

  if magnitude <= streamMaxExactMagnitude(T.self) {
    let unsigned = T(magnitude)
    let significand = negative ? -unsigned : unsigned
    if exponent == 0 { return significand }
    let index = exponent < 0 ? -exponent : exponent
    if index <= streamMaxExactPow10(T.self) {
      let scale = T(streamExactPow10(index))
      // Split so a corpus with only negative exponents does not execute an fdiv
      // for its positive-exponent path as well. No redundant init(exactly:) calls.
      if exponent >= 0 {
        let value = significand * scale
        // Exact operands can still produce an overflowing product (e.g. Float16).
        return value.isFinite ? value : nil
      }
      return significand / scale
    }
  }

  if let value = convertDecimal(magnitude, exponent, negative) { return value }
  return streamParseFloatingPointFallback(bytes, as: T.self)
}

@usableFromInline
func streamParseFloatingPointFallback<T: BinaryFloatingPoint & LosslessStringConvertible>(
  _ bytes: Span<UInt8>, as type: T.Type
) -> T? {
  // Numeric tokens are ASCII, so a scalar-wise build is exact.
  var text = ""
  text.reserveCapacity(bytes.count)
  for i in 0..<bytes.count {
    text.unicodeScalars.append(Unicode.Scalar(bytes[i]))
  }
  // Swift's Float16 string initializer can parse through Float and round twice.
  // The binary16 fallback uses Double, resolving exact midpoint ambiguities
  // against the original decimal digits before constructing the destination.
  if T.significandBitCount == 10, T.exponentBitCount == 5 {
    return streamParseHalfFallback(bytes, text: text, as: T.self)
  }
  // JSON has no infinity, and a token that scales past the type's range is out of range rather
  // than infinite, which is what the registration based parser reported too.
  guard let parsed = T(text), parsed.isFinite else { return nil }
  return parsed
}

// The standard library's own conformances live in Support/StandardLibrary.swift, next to the
// registration based ones they replace, so removing the old parser is a single subtraction.

// Walks the digits of an integer token. Reached only when the accumulated magnitude cannot be
// trusted, so it is off the hot path. No String, so it stays inside the embedded subset.
@usableFromInline
func _streamRescanInteger<T: FixedWidthInteger>(_ bytes: Span<UInt8>, as type: T.Type) -> T? {
  var index = 0
  var isNegative = false
  if index < bytes.count, bytes[index] == .asciiDash {
    guard T.isSigned else { return nil }
    isNegative = true
    index &+= 1
  }
  guard index < bytes.count else { return nil }

  var magnitude = T.Magnitude.zero
  while index < bytes.count {
    let byte = bytes[index]
    guard byte >= .asciiZero, byte <= .asciiNine else { return nil }
    let (multiplied, multiplyOverflowed) = magnitude.multipliedReportingOverflow(by: 10)
    guard !multiplyOverflowed else { return nil }
    let (added, addOverflowed) = multiplied.addingReportingOverflow(
      T.Magnitude(byte &- .asciiZero)
    )
    guard !addOverflowed else { return nil }
    magnitude = added
    index &+= 1
  }

  guard isNegative else { return T(exactly: magnitude) }
  guard magnitude <= T.min.magnitude else { return nil }
  return magnitude == T.min.magnitude ? T.min : 0 &- T(magnitude)
}
