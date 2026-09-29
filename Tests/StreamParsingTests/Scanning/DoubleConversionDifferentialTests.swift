import Foundation
import Testing

@testable import StreamParsingCore

// `Double(streamParsing:info:)` is three kernels behind one entry point -- an exact
// significand-times-power-of-ten path, Eisel-Lemire, and a `String` round trip -- and which one
// answers a given token is an implementation detail that has already been changed twice. What may
// never change is the answer: every token must come back correctly rounded, which is exactly what
// `Double(String)` returns.
//
// So this is a differential against the standard library over (a) every number token in the two
// float-heavy corpora, driven through the real parser so the `NumberInfo` under test is the one
// the parser actually produces, and (b) a hand-written table of the shapes the corpora do not
// contain: 17+ significant digits, leading zeros, negative zero, exponents at and beyond the
// table's edges, subnormals and the ends of the range.
//
// A token that scales out of range is `nil` here and `infinity` from the standard library -- JSON
// has no infinity, and the conversion has reported out-of-range as a refusal since the
// registration based parser -- so the oracle is normalised to `nil` for anything non-finite.
//
// The machinery is generic because `Float` runs the identical differential against
// `Float(String)`: see `FloatConversionDifferentialTests` for why that twin is worth having.

// MARK: - Shared differential machinery

typealias StreamDifferentialFloat =
  BinaryFloatingPoint & LosslessStringConvertible & StreamBinaryFormat

// Converts every number token the parser reports and records the ones that disagree with
// `T(String)`. Holds the text too, so a failure names the token rather than an index.
struct DifferentialSink<T: StreamDifferentialFloat>: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  private(set) var count = 0
  private(set) var nilCount = 0
  // Tokens the exact path provably cannot serve, and how many of those Eisel-Lemire answered.
  // Without the second number a regression that silently sent the type back to the `String`
  // fallback would pass every equality check in these files. Both cost a kernel call per token,
  // so they are only counted for the rows that assert on them.
  private(set) var beyondExactCount = 0
  private(set) var kernelCount = 0
  private(set) var mismatches: [String] = []
  private let tracksKernel: Bool

  init(tracksKernel: Bool = false) {
    self.tracksKernel = tracksKernel
  }

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    let text = bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
    self.count += 1

    if self.tracksKernel {
      let exponent = Int(info.exponent)
      let maxPow10 = streamMaxExactPow10(T.self)
      if !info.flags.contains(.overflowed),
        info.magnitude > streamMaxExactMagnitude(T.self)
          || exponent > maxPow10 || exponent < -maxPow10
      {
        self.beyondExactCount += 1
        let direct = streamEiselLemire(
          magnitude: info.magnitude,
          exponent: exponent,
          negative: info.flags.contains(.negative),
          as: T.self
        )
        if direct != nil { self.kernelCount += 1 }
      }
    }

    let oracle = T(text).flatMap { $0.isFinite ? $0 : nil }
    let value = T(streamParsing: bytes, info: info)
    if value == nil { self.nilCount += 1 }
    switch (value, oracle) {
    case (nil, nil):
      return
    case let (value?, oracle?) where streamBitParts(value) == streamBitParts(oracle):
      return
    default:
      guard self.mismatches.count < 16 else { return }
      self.mismatches.append("\(text): got \(streamDescribe(value)) want \(streamDescribe(oracle))")
    }
  }

  mutating func key(_ bytes: Span<UInt8>) {}
  mutating func beginObject() -> StreamContainerDisposition { .stream }
  mutating func endObject() {}
  mutating func beginArray() -> StreamContainerDisposition { .stream }
  mutating func endArray() {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}

// Bit-for-bit identity spelled through `BinaryFloatingPoint`, which has no `bitPattern`: sign plus
// the two raw patterns *is* the encoding, and comparing it rather than `==` is what keeps `-0`
// from passing as `0`. No token here produces a NaN.
private func streamBitParts<T: BinaryFloatingPoint>(
  _ value: T
) -> (FloatingPointSign, T.RawExponent, T.RawSignificand) {
  (value.sign, value.exponentBitPattern, value.significandBitPattern)
}

private func streamDescribe<T: BinaryFloatingPoint>(_ value: T?) -> String {
  guard let value else { return "nil" }
  let parts = streamBitParts(value)
  return "\(parts.0 == .minus ? "-" : "+")\(String(UInt64(parts.1), radix: 16))"
    + ":\(String(UInt64(parts.2), radix: 16))"
}

// Runs a document through the parser into a fresh differential sink.
func differentialCheck<T: StreamDifferentialFloat>(
  _ bytes: [UInt8],
  chunk: Int,
  as type: T.Type,
  tracksKernel: Bool = false
) throws -> DifferentialSink<T> {
  var sink = DifferentialSink<T>(tracksKernel: tracksKernel)
  try feed(bytes, chunk: chunk, into: &sink)
  return sink
}

// MARK: - Double

@Suite
struct `Double conversion differential tests` {
  @Test(arguments: ["canada.json", "mesh.json"])
  func `Every number in a float corpus converts exactly as Double(String) does`(
    name: String
  ) throws {
    let bytes = try #require(streamBenchmarkCorpus(name))
    let sink = try differentialCheck(bytes, chunk: .max, as: Double.self)
    #expect(sink.mismatches.isEmpty, "\(name): \(sink.mismatches)")
    #expect(sink.count > 1000)
    // The string fallback is correct but slow, so a change that started routing the corpus
    // through it would pass the equality check above while undoing the point of the kernels.
    #expect(sink.nilCount == 0)
  }

  // The same corpus cut into chunks, because a token split across a chunk boundary is reassembled
  // in the parser's buffer and reaches the conversion as a different `Span` carrying the same
  // `NumberInfo`.
  @Test
  func `A chunked float corpus converts identically`() throws {
    let bytes = try #require(streamBenchmarkCorpus("canada.json"))
    let sink = try differentialCheck(bytes, chunk: 4093, as: Double.self)
    #expect(sink.mismatches.isEmpty, "\(sink.mismatches)")
    #expect(sink.nilCount == 0)
  }

  @Test
  func `Edge case tokens convert exactly as Double(String) does`() throws {
    let tokens = [
      // Canada's own shape, and the digits past what a Double significand can hold.
      "-65.613616999999977", "43.420273000000009", "1.7976931348623157",
      "123456789012345678", "1234567890123456789", "12345678901234567890",
      "9007199254740993", "9007199254740992", "9007199254740991",
      "18446744073709551615", "18446744073709551616",
      // Leading zeros, in the integer part and in the fraction.
      "0", "-0", "0.0", "-0.0", "0.000000000000000123", "0.0000000000000000000001",
      // The exact path's edges: 10^22 is the last exactly representable power of ten.
      "1e22", "1e23", "1e-22", "1e-23", "-1e22", "-1e-22",
      // Subnormals and the ends of the range.
      "5e-324", "4.9e-324", "2.5e-324", "2.2250738585072014e-308",
      "2.2250738585072011e-308", "1.7976931348623157e308",
      "1e-308", "1e-310", "1e-320", "1e-323", "1e308", "1e-400", "1e400", "-1e400",
      // Halfway cases a 55-bit approximation cannot separate on its own.
      "7.8459735791271921e65", "3.5844466002796428e+298", "9.881312916824931e-324",
      // Exponent spellings.
      "1E2", "1e+2", "1e-2", "-1e-2", "1.0e0", "-1.0E+0",
      // Long digit runs, which cross the eight-digit block boundary in the accumulator.
      "1234567.8", "12345678.9", "123456789.01234567", "0.12345678901234567890123",
      "-0.00000000000000000000000000001", "1000000000000000000000",
    ]
    for token in tokens {
      let sink = try differentialCheck(Array(token.utf8), chunk: .max, as: Double.self)
      #expect(sink.count == 1, "\(token) produced \(sink.count) tokens")
      #expect(sink.mismatches.isEmpty, "\(sink.mismatches)")
    }
  }

  // The constants the kernel is parameterised on, checked against the type rather than against
  // the literals they are written as: a wrong one here is a silently wrong conversion in a corner
  // the differential above may not reach. `Float`'s twin lives in the other file.
  @Test
  func `The Double binary format constants describe Double`() {
    #expect(Double.streamMantissaBits == Double.significandBitCount)
    #expect(Double.streamMinExponent == -1023)
    #expect(Double.streamInfinitePower == 0x7FF)
    #expect(streamMaxExactPow10(Double.self) == 22)
    #expect(streamMaxExactMagnitude(Double.self) == 1 << 53)
  }
}
