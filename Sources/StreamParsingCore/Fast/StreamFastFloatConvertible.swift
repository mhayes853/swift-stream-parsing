/// A binary floating-point type with a fast decimal conversion path.
///
/// The default number initializer tries Clinger's exact conversion, then
/// ``streamConvertDecimal(magnitude:exponent:negative:)``, and finally the library's
/// complete-token fallback, normally using `LosslessStringConvertible`. An
/// overflowed decimal accumulator goes directly to that fallback.
///
/// The default fast conversion uses Eisel–Lemire with the shared powers of ten
/// from 10^-342 through 10^308. It supports finite binary formats with up to 64 bits
/// of precision, including `Float16`, `Float`, `Double`, and `Float80` where available.
/// Zero is accepted for every exponent.
/// Other formats can provide their own conversion or use the complete-token fallback.
public protocol StreamFastFloatConvertible:
  BinaryFloatingPoint, LosslessStringConvertible, StreamNumberConvertible
{
  /// Attempts conversion of `(-1)^negative * magnitude * 10^exponent`.
  ///
  /// A successful conversion must be finite and correctly rounded to nearest,
  /// ties to even. Preserve negative zero and permit underflow to signed zero.
  ///
  /// Return `nil` when the fast path cannot determine a finite result, for example
  /// when a nonzero input's exponent is outside its range. This requests the complete-token
  /// fallback; it does not establish that the input is invalid or unrepresentable.
  static func streamConvertDecimal(
    magnitude: UInt64,
    exponent: Int,
    negative: Bool
  ) -> Self?
}

extension StreamFastFloatConvertible {
  @inlinable
  public static func streamConvertDecimal(
    magnitude: UInt64,
    exponent: Int,
    negative: Bool
  ) -> Self? {
    streamEiselLemire(
      magnitude: magnitude,
      exponent: exponent,
      negative: negative,
      as: Self.self
    )
  }

  @inlinable
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard
      let value = streamParseFloatingPoint(
        bytes,
        info: info,
        as: Self.self,
        convertDecimal: Self.streamConvertDecimal
      )
    else { return nil }
    self = value
  }
}
