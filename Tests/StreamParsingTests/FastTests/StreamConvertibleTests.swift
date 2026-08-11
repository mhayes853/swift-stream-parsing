import Testing

import StreamParsing
@testable import StreamParsingCore

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
      #expect(Int(streamParsing: bytes, info: Self.info(4217, digits: 4)) == 4217)
      #expect(UInt8(streamParsing: bytes, info: Self.info(217, digits: 3)) == 217)
    }
  }

  @Test
  func `Negative magnitudes convert`() {
    Self.span("-4217") { bytes in
      let info = Self.info(4217, digits: 4, flags: .negative)
      #expect(Int(streamParsing: bytes, info: info) == -4217)
    }
  }

  // Two's complement asymmetry: the magnitude of `min` is one greater than that of `max`, so
  // the boundary needs its own path rather than negating a parsed positive.
  @Test
  func `Signed minimums convert`() {
    Self.span("-128") { bytes in
      let info = Self.info(128, digits: 3, flags: .negative)
      #expect(Int8(streamParsing: bytes, info: info) == Int8.min)
    }
    Self.span("-9223372036854775808") { bytes in
      let info = Self.info(9_223_372_036_854_775_808, digits: 19, flags: .negative)
      #expect(Int64(streamParsing: bytes, info: info) == Int64.min)
    }
  }

  @Test
  func `Values beyond the destination range are rejected`() {
    Self.span("256") { bytes in
      #expect(UInt8(streamParsing: bytes, info: Self.info(256, digits: 3)) == nil)
    }
    Self.span("-129") { bytes in
      let info = Self.info(129, digits: 3, flags: .negative)
      #expect(Int8(streamParsing: bytes, info: info) == nil)
    }
    Self.span("128") { bytes in
      #expect(Int8(streamParsing: bytes, info: Self.info(128, digits: 3)) == nil)
    }
  }

  @Test
  func `Overflowed magnitudes are rejected rather than truncated`() {
    Self.span("99999999999999999999999") { bytes in
      let info = Self.info(0, digits: 23, flags: .overflowed)
      #expect(Int(streamParsing: bytes, info: info) == nil)
      #expect(UInt64(streamParsing: bytes, info: info) == nil)
    }
  }

  @Test
  func `Fractional and exponential tokens are not integers`() {
    Self.span("1.5") { bytes in
      let info = Self.info(15, digits: 2, exponent: -1, flags: .fraction)
      #expect(Int(streamParsing: bytes, info: info) == nil)
    }
    Self.span("1e3") { bytes in
      let info = Self.info(1, digits: 1, exponent: 3, flags: .exponent)
      #expect(Int(streamParsing: bytes, info: info) == nil)
    }
  }

  // MARK: - Floating point

  @Test
  func `Whole doubles use the accumulated magnitude`() {
    Self.span("42") { bytes in
      #expect(Double(streamParsing: bytes, info: Self.info(42, digits: 2)) == 42)
    }
    Self.span("-42") { bytes in
      let info = Self.info(42, digits: 2, flags: .negative)
      #expect(Double(streamParsing: bytes, info: info) == -42)
    }
  }

  @Test
  func `Fractional and exponential doubles re-scan the span`() {
    Self.span("98.25") { bytes in
      let info = Self.info(9825, digits: 4, exponent: -2, flags: .fraction)
      #expect(Double(streamParsing: bytes, info: info) == 98.25)
    }
    Self.span("1.5e-8") { bytes in
      let info = Self.info(15, digits: 2, exponent: -9, flags: [.fraction, .exponent])
      #expect(Double(streamParsing: bytes, info: info) == 1.5e-8)
    }
    Self.span("-98.25") { bytes in
      let info = Self.info(9825, digits: 4, exponent: -2, flags: [.fraction, .negative])
      #expect(Double(streamParsing: bytes, info: info) == -98.25)
    }
  }

  // MARK: - Strings

  @Test
  func `String appends accumulate across calls`() {
    var value = String.streamInitialValue()
    Self.span("Blob") { value.streamAppend(utf8: $0) }
    Self.span(" Jr") { value.streamAppend(utf8: $0) }
    #expect(value == "Blob Jr")
  }

  @Test
  func `String appends preserve multi byte UTF-8`() {
    var value = String.streamInitialValue()
    Self.span("Aé€😀") { value.streamAppend(utf8: $0) }
    #expect(value == "Aé€😀")
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
      streamApply(&name, utf8: bytes)
      streamApply(&count, utf8: bytes)
      streamApply(&flag, utf8: bytes)
      streamApply(&opaque, utf8: bytes)
    }
    Self.span("42") { bytes in
      let info = Self.info(42, digits: 2)
      streamApply(&name, bytes: bytes, info: info)
      streamApply(&count, bytes: bytes, info: info)
      streamApply(&opaque, bytes: bytes, info: info)
    }
    streamApply(&flag, boolean: true)
    streamApply(&count, boolean: true)

    #expect(name == "Blob")
    #expect(count == 42)
    #expect(flag)
    #expect(opaque == Opaque())
  }

  @Test
  func `Null application only affects nullable destinations`() {
    var optional: Int? = 5
    var plain = 5
    streamApplyNull(&optional)
    streamApplyNull(&plain)
    #expect(optional == nil)
    #expect(plain == 5)
  }
}
