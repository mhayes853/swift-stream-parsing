import Testing

@testable import StreamParsingCore

// The `Float` twin of `DoubleConversionDifferentialTests`, running the same generic
// `DifferentialSink`, and the reason it is worth having twice: `Float` used to get only the exact
// significand-times-power-of-ten path (a 2^24 significand and 10^±10, a window narrow enough that
// most real decimals miss it) and then a `String` round trip. It now gets its own instantiation of
// Eisel-Lemire, with `Float`'s mantissa width, bias, infinite power, round-to-even window and
// subnormal cutoff.
//
// The instantiation is what has to be tested, not the algorithm: a kernel that computed a
// `Double` and narrowed would pass a loose tolerance check and still be wrong, because
// decimal -> `Double` -> `Float` rounds twice. So the oracle is `Float(String)`, the comparison is
// bit-for-bit, and the corpus rows push every number in `canada.json` and `mesh.json` through it.
//
// A token that scales out of `Float`'s range is `nil` here and `infinity` from the standard
// library -- JSON has no infinity -- so the oracle is normalised to `nil` for anything non-finite.
// That bites far more often for `Float` than for `Double`: `1e39` is an ordinary `Double`.

@Suite
struct `Float conversion differential tests` {
  // `canada.json` is parsed once for the two rows that read it whole: the differential below and
  // the kernel-coverage property, which is a question about the same sink rather than a second
  // pass over 2.2 MB. A `Result` rather than an optional so a parse failure is still raised by
  // whichever row runs first instead of being reported as a missing corpus.
  private static let canada: Result<DifferentialSink<Float>?, any Error> = Result {
    guard let bytes = streamBenchmarkCorpus("canada.json") else { return nil }
    return try differentialCheck(bytes, chunk: .max, as: Float.self, tracksKernel: true)
  }

  @Test(arguments: ["canada.json", "mesh.json"])
  func `Every number in a float corpus converts exactly as Float(String) does`(
    name: String
  ) throws {
    let sink: DifferentialSink<Float>
    if name == "canada.json" {
      sink = try #require(try Self.canada.get())
    } else {
      let bytes = try #require(streamBenchmarkCorpus(name))
      sink = try differentialCheck(bytes, chunk: .max, as: Float.self)
    }
    #expect(sink.mismatches.isEmpty, "\(name): \(sink.mismatches)")
    #expect(sink.count > 1000)
    #expect(sink.nilCount == 0)
  }

  // A token split across a chunk boundary is reassembled in the parser's buffer and reaches the
  // conversion as a different `Span` carrying the same `NumberInfo`.
  @Test
  func `A chunked float corpus converts identically for Float`() throws {
    let bytes = try #require(streamBenchmarkCorpus("canada.json"))
    let sink = try differentialCheck(bytes, chunk: 4093, as: Float.self)
    #expect(sink.mismatches.isEmpty, "\(sink.mismatches)")
    #expect(sink.nilCount == 0)
  }

  // The point of the change, stated as a property rather than as a benchmark: essentially every
  // token in `canada.json` is outside `Float`'s exact window (a 2^24 significand and 10^±10) and
  // the kernel -- not the `String` fallback -- is what answers it.
  @Test
  func `Float reaches the Eisel-Lemire kernel rather than the string fallback`() throws {
    let sink = try #require(try Self.canada.get())
    // canada.json is 17-significant-digit coordinates, so the exact path can take almost none.
    #expect(sink.beyondExactCount > sink.count / 2)
    // And the kernel declines only the handful of halfway cases it refuses to guess at.
    let declined = sink.beyondExactCount - sink.kernelCount
    #expect(
      declined * 100 < sink.beyondExactCount,
      "kernel declined \(declined) of \(sink.beyondExactCount)"
    )
  }

  // Single tokens, with no corpus dependency, that prove the kernel answers and is bit-exact on
  // decimals the exact path cannot reach. An exact halfway value such as `16777217` is *not* in
  // this list on purpose: it is precisely what the round-to-even window makes the kernel decline,
  // and the edge case table below is where its answer is checked.
  @Test(
    arguments: [
      "3.14159265358979", "1.7014118e38", "2.5e-30", "1.23456789e-20",
      "7.038531e-26",  // the classic decimal -> Double -> Float double-rounding counterexample
      "9.8813129e-324", "8.589973e-30", "1.1754944e-38", "3.4028235e38",
    ]
  )
  func `The Float kernel answers and is bit exact`(token: String) throws {
    let sink = try differentialCheck(
      Array(token.utf8), chunk: .max, as: Float.self, tracksKernel: true
    )
    #expect(sink.count == 1)
    #expect(sink.mismatches.isEmpty, "\(sink.mismatches)")
    #expect(sink.beyondExactCount == 1, "\(token) was inside the exact window")
    #expect(sink.kernelCount == 1, "\(token) was declined by the kernel")
  }

  @Test
  func `Edge case tokens convert exactly as Float(String) does`() throws {
    let tokens = [
      // Halfway points of the 24-bit significand.
      "1.00000005960464477539062",  // exactly halfway between 1 and nextUp(1)
      "1.00000005960464477539063", "1.00000005960464477539061",
      "1.00000011920928955078125", "1.00000017881393432617188",
      "16777215", "16777216", "16777217", "16777218", "16777219", "16777220",
      "33554431", "33554433", "33554435",
      // The top of the range and the overflow boundary: the largest decimal that still rounds to
      // greatestFiniteMagnitude, and the first that does not.
      "3.4028235e38", "3.4028234e38", "3.40282356779733661637539395458142568448e38",
      "3.4028236e38", "3.5e38", "1e39", "-3.4028236e38",
      // Subnormals, the smallest one, the round-to-zero boundary and the normal/subnormal seam.
      "1e-45", "1.4e-45", "7e-46", "7.0064923216240853546e-46", "6.9e-46", "1e-46", "1e-50",
      "1.17549435e-38", "1.1754943e-38", "1.1754942e-38", "1.17549421069244107548702944485e-38",
      "1e-38", "1e-40", "1e-44",
      // Zeros and signs.
      "0", "-0", "0.0", "-0.0", "0e10", "-0e-10", "0.0000000000000000000001",
      // 19-digit magnitudes, and the twenty-digit token whose accumulator has wrapped.
      "1234567890123456789", "9999999999999999999", "1000000000000000000",
      "12345678901234567890", "18446744073709551615", "18446744073709551616",
      // Exponents past the 128-bit table's ends, and past Float's range in both directions.
      "1e400", "1e-400", "-1e400", "1e-330", "1e310", "1.5e-322",
      // The exact path's own edges for Float: 10^10 is the last exactly representable power.
      "1e10", "1e11", "1e-10", "1e-11", "-1e10", "-1e-10", "123456e10", "16777216e-10",
      // Ordinary shapes, exponent spellings, long digit runs.
      "1E2", "1e+2", "1e-2", "-1.0E+0", "1234567.8", "12345678.9", "123456789.01234567",
      "0.12345678901234567890123", "-0.00000000000000000000000000001",
      "-65.613616999999977", "43.420273000000009",
    ]
    for token in tokens {
      let sink = try differentialCheck(Array(token.utf8), chunk: .max, as: Float.self)
      #expect(sink.count == 1, "\(token) produced \(sink.count) tokens")
      #expect(sink.mismatches.isEmpty, "\(sink.mismatches)")
    }
  }

  // The constants the kernel is parameterised on, checked against the type rather than against
  // the literals they are written as: a wrong one here is a silently wrong conversion in a corner
  // the differential above may not reach.
  @Test
  func `The Float binary format constants describe Float`() {
    #expect(Float.streamMantissaBits == Float.significandBitCount)
    #expect(Float.streamMinExponent == -((1 << (Float.exponentBitCount - 1)) - 1))
    #expect(Float.streamInfinitePower == (1 << Float.exponentBitCount) - 1)
    #expect(
      Float.streamFromBits(Float.greatestFiniteMagnitude.bitPattern) == .greatestFiniteMagnitude
    )
    // `10^k` is exact in Float up to k = 10 (5^10 < 2^24) and not beyond.
    #expect(streamMaxExactPow10(Float.self) == 10)
    #expect(streamMaxExactMagnitude(Float.self) == 1 << 24)
    // Above the cutoff no significand can produce a subnormal; at it, 1e-38 is one.
    #expect(Float.streamSubnormalCutoff == -38)
    #expect(Float("1e-38")!.exponent < Float.leastNormalMagnitude.exponent)
    #expect(Float("1e-37")!.exponent >= Float.leastNormalMagnitude.exponent)
  }
}
