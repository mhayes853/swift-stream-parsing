// MARK: - Protocols

// Anything a container can hold, since an element has to exist before it can be written into.
public protocol StreamInitializable: SendableMetatype {
  static func streamInitialValue() -> Self
}

public protocol StreamStringConvertible: StreamInitializable {
  // Returns whether the bytes were taken. Unbounded storage answers `.applied` unconditionally
  // and the result folds away on specialization; bounded storage is the reason the result exists,
  // and answers `.capacityExceeded` without taking any of the bytes, so a value holds exactly
  // what it accumulated up to the last append that fit.
  @discardableResult
  mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult

  // How a schema recognizes fixed-capacity inline storage without being able to name it.
  //
  // `_streamStringSchema` is generic over the destination and cannot spell
  // `StreamInlineString<capacity>` for a capacity it does not know, and an existential metatype
  // cast to ask the question would not survive into Embedded Swift. A static requirement with a
  // default answers it instead: it is read once when a schema is built, never per token, and
  // specializes to a constant that folds the branch away for every type that leaves it zero.
  //
  // Zero means "not inline storage". A non-zero value is a promise about layout, checked in
  // `_streamStringSchema`: `_streamInlineByteOffset` bytes of header, then exactly that many
  // bytes of UTF-8 storage, which is what lets `PartialSink` append to it without naming it.
  static var _streamInlineCapacity: Int { get }
  static var _streamInlineByteOffset: Int { get }
}

extension StreamStringConvertible {
  @inlinable
  public static var _streamInlineCapacity: Int { 0 }
  @inlinable
  public static var _streamInlineByteOffset: Int { 0 }
}

public protocol StreamNumberConvertible: SendableMetatype {
  init?(streamParsing bytes: Span<UInt8>, info: NumberInfo)
}

public protocol StreamBooleanConvertible: SendableMetatype {
  init(streamParsingBoolean value: Bool)
}

public protocol StreamNullable: SendableMetatype {
  static func streamNullValue() -> Self
}

// MARK: - Integers

extension FixedWidthInteger {
  // A token carrying an exponent is rejected rather than scaled, matching prior behaviour.
  // Inlinable so a generic caller specialised for a concrete integer gets a specialised
  // conversion: reached through the protocol witness alone this ran unspecialised, with a
  // metadata lookup per number, and the batch appender measured Mesh at half speed.
  @inlinable
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard !info.flags.contains(.fraction), info.exponent == 0 else { return nil }

    // The accumulator flags anything it could not hold in a UInt64, which includes values that
    // do fit the destination: UInt64.max is twenty digits. Walking the token settles it rather
    // than rejecting a number the type can represent.
    if info.flags.contains(.overflowed) {
      guard let rescanned = _streamRescanInteger(bytes, as: Self.self) else { return nil }
      self = rescanned
      return
    }

    if info.flags.contains(.negative) {
      guard Self.isSigned else { return nil }
      // Integer-to-integer `init?(exactly:)` is `@inlinable` in the standard library and folds to
      // a range compare, so the argument the floating-point path below makes against
      // `init(exactly:)` -- an out-of-line `bl` with a float round trip inside it -- does not
      // apply to either use here.
      //
      // The bound is expressed in Self.Magnitude rather than UInt64, because widening the
      // other way traps for types wider than 64 bits.
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

extension BinaryFloatingPoint where Self: LosslessStringConvertible {
  // Accumulation rather than a string round trip, in three tiers, none of which is written for
  // one concrete type.
  //
  // 1. The Clinger exact path. Both operands of the scale are exact when the significand fits the
  //    significand field and the power of ten is in the exactly representable range, so a single
  //    multiply or divide gives the correctly rounded result. Both bounds are properties of
  //    `Self` -- `2^(significandBitCount + 1)` and `streamMaxExactPow10` -- and both fold to
  //    immediates when the generic specialises: 2^53 / 10^22 for `Double`, 2^24 / 10^10 for
  //    `Float`.
  // 2. Eisel-Lemire, parameterised on `Self`'s binary format. Reached by every token the exact
  //    path cannot take, which on `canada.json` is 91.2% of them.
  // 3. The standard library's parser, for the cases the kernel declines and for a token of more
  //    than nineteen digits, whose accumulated `magnitude` has wrapped.
  //
  // This used to fold `Self.self == Double.self` and jump to a separate non-generic body, because
  // the generic spelling charged every type for three conversions that are identities or
  // constant folds. Reading the release binary showed all three were `init(exactly:)`, not
  // genericity:
  //
  //   * `Self(exactly: info.magnitude)` stayed an out-of-line `bl` to
  //     `Double.init<UInt64>(exactly:)` -- a `ucvtf`, an `fcmp` against 2^64, an `fcvtzu` back and
  //     a compare -- executed for **every** number and discarded for the 91% of `canada.json`
  //     whose significand exceeds 2^53. `Self(_:)` on the same operand is a bare `ucvtf`; the
  //     range question is answered by the `magnitude <= 2^(significandBitCount + 1)` compare that
  //     has to happen anyway, because a magnitude above that bound is unusable by this path even
  //     when it happens to be representable.
  //   * `Self(exactly: scale)` on a `.rodata` power of ten emitted `fcmp d1, d1; b.vs` -- a NaN
  //     test on a compile-time-constant table entry -- and was doing duty as the type-dependent
  //     Clinger window. `streamMaxExactPow10(Self.self)` is that window as a constant.
  //   * `Self(exactly: value)` on Eisel-Lemire's result emitted an infinity/NaN test on a kernel
  //     that returns neither.
  //
  // With those gone the `Double` specialisation is the straight-line kernel the special case
  // used to provide, and `Float` gets the same three tiers instead of exact-or-`String`.
  //
  // The sign is applied to the significand before the scale rather than to the result: a power of
  // ten is positive, so multiplying or dividing carries the sign through unchanged, zero
  // included, and doing it here costs the same two instructions (`fneg`/`fcsel`) the old
  // `Double`-only body spent OR-ing the sign bit into the finished bit pattern -- while staying
  // expressible for a `Self` whose bit pattern this extension cannot name.
  @inlinable
  public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    // Tested against the raw bits rather than through `contains`, so the two tests are a `tbnz`
    // pair on a register the caller already holds rather than two `OptionSet` calls. The masks
    // are the flags' own `rawValue`s: those statics are `@inlinable` and computed, so each folds
    // to its immediate and no bit index is written down twice.
    let flags = info.flags.rawValue
    guard flags & NumberInfo.Flags.overflowed.rawValue == 0 else {
      // More than nineteen digits: `magnitude` has wrapped, so nothing below may look at it.
      guard let fallback = streamParseFloatingPointFallback(bytes, as: Self.self) else {
        return nil
      }
      self = fallback
      return
    }

    let magnitude = info.magnitude
    let exponent = Int(info.exponent)
    let negative = flags & NumberInfo.Flags.negative.rawValue != 0

    if magnitude <= streamMaxExactMagnitude(Self.self) {
      let unsigned = Self(magnitude)
      let significand = negative ? -unsigned : unsigned
      if exponent == 0 {
        self = significand
        return
      }
      let index = exponent < 0 ? -exponent : exponent
      if index <= streamMaxExactPow10(Self.self) {
        let scale = Self(streamExactPow10(index))
        // Split rather than written as one `?:` so a corpus whose exponents all have one sign
        // pays a predicted branch instead of an unconditional `fdiv` it throws away.
        if exponent >= 0 {
          self = significand * scale
          return
        }
        self = significand / scale
        return
      }
    }

    if let value = streamEiselLemireAny(
      magnitude: magnitude,
      exponent: exponent,
      negative: negative,
      as: Self.self
    ) {
      self = value
      return
    }

    guard let fallback = streamParseFloatingPointFallback(bytes, as: Self.self) else {
      return nil
    }
    self = fallback
  }
}

// Eisel-Lemire for the formats that have a `StreamBinaryFormat`, and a decline for every other
// `BinaryFloatingPoint`.
//
// The extension above is on `BinaryFloatingPoint where Self: LosslessStringConvertible`, a
// constraint set this package does not own, so it cannot require the format conformance the
// kernel needs; a type test is the only way to ask. Both comparisons fold to constants when the
// generic specialises -- the `Double` specialisation is left with the kernel call and nothing
// else -- and a type without a format (`Float80`, `CGFloat`, a user's own) declines here and
// takes the `String` fallback, exactly as it did before.
//
// `Float` is emphatically *not* served by computing a `Double` and narrowing: decimal -> `Double`
// -> `Float` rounds twice and is not correctly rounded in general (`7.038531e-26` is the
// classic). It gets its own instantiation of the kernel, with its own constants.
@inlinable
@inline(__always)
func streamEiselLemireAny<T: BinaryFloatingPoint>(
  magnitude: UInt64, exponent: Int, negative: Bool, as type: T.Type
) -> T? {
  // Guarded by the type test, so the `unsafeBitCast` is a no-op on the only branch that can
  // reach it and dead code on every other specialisation. The arms differ only in which format
  // they instantiate, so the body is written once and each call folds to its own kernel.
  // Spelled with a `guard` rather than `.map`: the closure `.map` takes is a real closure in the
  // *unspecialised* generic, which reached it through `__swift_instantiateConcreteTypeFromMangled
  // NameV2` and three partial-apply forwarders. The specialisations fold either form away.
  @inline(__always)
  func bridge<F: StreamBinaryFormat>(_ format: F.Type) -> T? {
    guard
      let value = streamEiselLemire(
        magnitude: magnitude, exponent: exponent, negative: negative, as: F.self
      )
    else { return nil }
    return unsafeBitCast(value, to: T.self)
  }
  if T.self == Double.self { return bridge(Double.self) }
  if T.self == Float.self { return bridge(Float.self) }
  return nil
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
