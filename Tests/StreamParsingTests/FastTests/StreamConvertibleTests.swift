import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

@Suite
struct `Stream convertible tests` {
  private static func span<R>(_ text: String, _ body: (Span<UInt8>) -> R) -> R {
    let bytes = Array(text.utf8)
    return bytes.withUnsafeBufferPointer { body(Span(_unsafeElements: $0)) }
  }

  private static func info(
    _ magnitude: UInt64, digits: UInt16, exponent: Int16 = 0, flags: NumberInfo.Flags = []
  ) -> NumberInfo {
    NumberInfo(magnitude: magnitude, exponent: exponent, digitCount: digits, flags: flags)
  }

  // MARK: - Integers

  @Test
  func `Exact magnitudes convert without re-scanning`() {
    Self.span("4217") { bytes in
      expectNoDifference(Int(streamParsing: bytes, info: Self.info(4217, digits: 4)), 4217)
      expectNoDifference(UInt8(streamParsing: bytes, info: Self.info(217, digits: 3)), 217)
    }
  }

  @Test
  func `Negative magnitudes convert`() {
    Self.span("-4217") { bytes in
      let info = Self.info(4217, digits: 4, flags: .negative)
      expectNoDifference(Int(streamParsing: bytes, info: info), -4217)
    }
  }

  // Two's complement asymmetry: the magnitude of `min` is one greater than that of `max`, so
  // the boundary needs its own path rather than negating a parsed positive.
  @Test
  func `Signed minimums convert`() {
    Self.span("-128") { bytes in
      let info = Self.info(128, digits: 3, flags: .negative)
      expectNoDifference(Int8(streamParsing: bytes, info: info), Int8.min)
    }
    Self.span("-9223372036854775808") { bytes in
      let info = Self.info(9_223_372_036_854_775_808, digits: 19, flags: .negative)
      expectNoDifference(Int64(streamParsing: bytes, info: info), Int64.min)
    }
  }

  @Test
  func `Values beyond the destination range are rejected`() {
    Self.span("256") { bytes in
      expectNoDifference(UInt8(streamParsing: bytes, info: Self.info(256, digits: 3)), nil)
    }
    Self.span("-129") { bytes in
      let info = Self.info(129, digits: 3, flags: .negative)
      expectNoDifference(Int8(streamParsing: bytes, info: info), nil)
    }
    Self.span("128") { bytes in
      expectNoDifference(Int8(streamParsing: bytes, info: Self.info(128, digits: 3)), nil)
    }
  }

  @Test
  func `Overflowed magnitudes are rejected rather than truncated`() {
    Self.span("99999999999999999999999") { bytes in
      let info = Self.info(0, digits: 23, flags: .overflowed)
      expectNoDifference(Int(streamParsing: bytes, info: info), nil)
      expectNoDifference(UInt64(streamParsing: bytes, info: info), nil)
    }
  }

  @Test
  func `Fractional and exponential tokens are not integers`() {
    Self.span("1.5") { bytes in
      let info = Self.info(15, digits: 2, exponent: -1, flags: .fraction)
      expectNoDifference(Int(streamParsing: bytes, info: info), nil)
    }
    Self.span("1e3") { bytes in
      let info = Self.info(1, digits: 1, exponent: 3, flags: .exponent)
      expectNoDifference(Int(streamParsing: bytes, info: info), nil)
    }
  }

  // MARK: - 128 bit integers

  // The accumulator's magnitude is a UInt64, so these two types are the only ones that can hold
  // a token it cannot. They re-scan the span instead of rejecting it, which is what the
  // registration based parser did.

  @Test
  @available(StreamParsing128BitIntegers, *)
  func `128 bit integers take the accumulated magnitude when it fits`() {
    Self.span("4217") { bytes in
      expectNoDifference(Int128(streamParsing: bytes, info: Self.info(4217, digits: 4)), 4217)
      expectNoDifference(UInt128(streamParsing: bytes, info: Self.info(4217, digits: 4)), 4217)
    }
    Self.span("-4217") { bytes in
      let info = Self.info(4217, digits: 4, flags: .negative)
      expectNoDifference(Int128(streamParsing: bytes, info: info), -4217)
      expectNoDifference(UInt128(streamParsing: bytes, info: info), nil)
    }
  }

  @Test
  @available(StreamParsing128BitIntegers, *)
  func `128 bit integers re-scan a magnitude too wide for the accumulator`() {
    Self.span("170141183460469231731687303715884105727") { bytes in
      let info = Self.info(0, digits: 39, flags: .overflowed)
      expectNoDifference(Int128(streamParsing: bytes, info: info), Int128.max)
      expectNoDifference(UInt128(streamParsing: bytes, info: info), 170_141_183_460_469_231_731_687_303_715_884_105_727)
    }
    Self.span("-170141183460469231731687303715884105728") { bytes in
      let info = Self.info(0, digits: 39, flags: [.overflowed, .negative])
      expectNoDifference(Int128(streamParsing: bytes, info: info), Int128.min)
      expectNoDifference(UInt128(streamParsing: bytes, info: info), nil)
    }
    Self.span("340282366920938463463374607431768211455") { bytes in
      let info = Self.info(0, digits: 39, flags: .overflowed)
      expectNoDifference(UInt128(streamParsing: bytes, info: info), UInt128.max)
      expectNoDifference(Int128(streamParsing: bytes, info: info), nil)
    }
  }

  @Test
  @available(StreamParsing128BitIntegers, *)
  func `128 bit integers reject what still does not fit`() {
    Self.span("340282366920938463463374607431768211456") { bytes in
      let info = Self.info(0, digits: 39, flags: .overflowed)
      expectNoDifference(UInt128(streamParsing: bytes, info: info), nil)
    }
    // A re-scan only makes sense for a plain integer token, so these stay rejected.
    Self.span("1.5") { bytes in
      let info = Self.info(15, digits: 2, exponent: -1, flags: .fraction)
      expectNoDifference(Int128(streamParsing: bytes, info: info), nil)
    }
    Self.span("1e300") { bytes in
      let info = Self.info(1, digits: 1, exponent: 300, flags: .exponent)
      expectNoDifference(Int128(streamParsing: bytes, info: info), nil)
    }
  }

  // MARK: - Floating point

  @Test
  func `Whole doubles use the accumulated magnitude`() {
    Self.span("42") { bytes in
      expectNoDifference(Double(streamParsing: bytes, info: Self.info(42, digits: 2)), 42)
    }
    Self.span("-42") { bytes in
      let info = Self.info(42, digits: 2, flags: .negative)
      expectNoDifference(Double(streamParsing: bytes, info: info), -42)
    }
  }

  @Test
  func `Fractional and exponential doubles re-scan the span`() {
    Self.span("98.25") { bytes in
      let info = Self.info(9825, digits: 4, exponent: -2, flags: .fraction)
      expectNoDifference(Double(streamParsing: bytes, info: info), 98.25)
    }
    Self.span("1.5e-8") { bytes in
      let info = Self.info(15, digits: 2, exponent: -9, flags: [.fraction, .exponent])
      expectNoDifference(Double(streamParsing: bytes, info: info), 1.5e-8)
    }
    Self.span("-98.25") { bytes in
      let info = Self.info(9825, digits: 4, exponent: -2, flags: [.fraction, .negative])
      expectNoDifference(Double(streamParsing: bytes, info: info), -98.25)
    }
  }

  // MARK: - Strings

  @Test
  func `String appends accumulate across calls`() {
    var value = String.streamInitialValue()
    Self.span("Blob") { value.streamAppend(utf8: $0) }
    Self.span(" Jr") { value.streamAppend(utf8: $0) }
    expectNoDifference(value, "Blob Jr")
  }

  @Test
  func `String appends preserve multi byte UTF-8`() {
    var value = String.streamInitialValue()
    Self.span("Aé€😀") { value.streamAppend(utf8: $0) }
    expectNoDifference(value, "Aé€😀")
  }

  // MARK: - Bridging

  // The macro emits every field into every apply switch and lets overload resolution decide,
  // because it cannot tell from syntax which token kind a type accepts. A type that accepts
  // neither must silently keep its value rather than fail to compile.
  private struct Opaque: Equatable {
    var value = 7
  }

  @Test
  func `Bridging shims apply matching kinds and ignore the rest`() {
    var name = String.streamInitialValue()
    var count = 0
    var flag = false
    var opaque = Opaque()

    Self.span("Blob") { bytes in
      expectNoDifference(streamApply(&name, utf8: bytes), .applied)
      expectNoDifference(streamApply(&count, utf8: bytes), .unsupported)
      expectNoDifference(streamApply(&flag, utf8: bytes), .unsupported)
      expectNoDifference(streamApply(&opaque, utf8: bytes), .unsupported)
    }
    Self.span("42") { bytes in
      let info = Self.info(42, digits: 2)
      expectNoDifference(streamApply(&name, bytes: bytes, info: info), .unsupported)
      expectNoDifference(streamApply(&count, bytes: bytes, info: info), .applied)
      expectNoDifference(streamApply(&opaque, bytes: bytes, info: info), .unsupported)
    }
    expectNoDifference(streamApply(&flag, boolean: true), .applied)
    expectNoDifference(streamApply(&count, boolean: true), .unsupported)

    expectNoDifference(name, "Blob")
    expectNoDifference(count, 42)
    expectNoDifference(flag, true)
    expectNoDifference(opaque, Opaque())
  }

  @Test
  func `Null application only affects nullable destinations`() {
    var optional: Int? = 5
    var plain = 5
    expectNoDifference(streamApplyNull(&optional), .applied)
    expectNoDifference(streamApplyNull(&plain), .unsupported)
    expectNoDifference(optional, nil)
    expectNoDifference(plain, 5)
  }
}
