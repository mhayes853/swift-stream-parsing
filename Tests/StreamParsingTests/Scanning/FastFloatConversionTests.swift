import Foundation
import StreamParsing
import Testing

@testable import StreamParsingCore

private struct FastFloatRandom {
  var state: UInt64 = 0x2026_0929_F10A_1234

  mutating func next() -> UInt64 {
    self.state ^= self.state << 13
    self.state ^= self.state >> 7
    self.state ^= self.state << 17
    return self.state
  }
}

// Exercise the public default without allowing a fallback to hide kernel errors.
// Compare the logical encoding so signed zero and Float80's padding are handled correctly.
private func checkFastFloatKernel<T: StreamFastFloatConvertible>(
  _ type: T.Type
) -> (accepted: Int, mismatches: [String]) {
  var random = FastFloatRandom()
  var accepted = 0
  var mismatches: [String] = []
  for exponent in streamPow10MinExponent...streamPow10MaxExponent {
    for _ in 0..<128 {
      let width = random.next() % 64
      let magnitude = random.next() >> width
      let negative = random.next() & 1 != 0
      let token = "\(negative ? "-" : "")\(magnitude)e\(exponent)"
      guard
        let actual = T.streamConvertDecimal(
          magnitude: magnitude,
          exponent: exponent,
          negative: negative
        )
      else { continue }
      accepted += 1
      guard let expected = T(token), actual.isFinite,
        actual.sign == expected.sign,
        actual.exponentBitPattern == expected.exponentBitPattern,
        actual.significandBitPattern == expected.significandBitPattern
      else {
        if mismatches.count < 16 { mismatches.append(token) }
        continue
      }
    }
  }
  return (accepted, mismatches)
}

#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
  @available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
  @StreamParseable
  private struct HalfFloatFields {
    // `optional` stays ahead of `scalar`: a `Float16` stored property directly followed by a
    // two-byte optional (`Float16?`, `Int16?`) gets an overlapping native-convention lowering on
    // x86_64, which trips `!paddingSize.isNegative()` in IRGen under assertion toolchains and
    // miscompiles the tail under release ones. Swift 6.3.x and 6.4 nightly are both affected.
    var optional: Float16?
    var scalar: Float16 = 0
    var array: [Float16] = []
    var dictionary: [String: Float16] = [:]
  }

  @Suite
  struct `Float16 fast conversion tests` {
    // Float16(String) parses through Float and can round twice on corpus tokens
    // near a half midpoint. Corpus decimals are short enough for this wider
    // reference; arbitrarily close long decimals use explicit expected encodings below.
    @available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
    private static func reference(_ text: String) -> Float16? {
      guard let value = Double(text) else { return nil }
      return Float16(value)
    }

    @Test
    func `Public half kernel is bit exact across the table`() {
      guard #available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) else { return }
      let result = checkFastFloatKernel(Float16.self)
      #expect(result.mismatches.isEmpty, "\(result.mismatches)")
      #expect(result.accepted > 35_000)
    }

    @Test
    func `Every finite half encoding round trips through number parsing`() throws {
      guard #available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) else { return }
      let values = (UInt32(0)...UInt32(UInt16.max))
        .compactMap { bits -> Float16? in
          let value = Float16(bitPattern: UInt16(bits))
          return value.isFinite ? value : nil
        }
      let document = "[" + values.map(\.description).joined(separator: ",") + "]"
      var parsed = StreamArray<Float16>()
      try parsePartial(document, into: &parsed, chunk: 4093)
      #expect(parsed.count == values.count)
      #expect(Array(parsed).map(\.bitPattern) == values.map(\.bitPattern))
    }

    @Test
    func `Halfway subnormal and overflow tokens match direct half rounding`() throws {
      guard #available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) else { return }
      let tokens = [
        "-0", "-0e400", "-0e-400", "2049", "2051", "65504", "65519", "65520",
        "65536", "2048e4", "7e4", "-7e4", "1e5", "1e-5", "1e-8", "1e-400",
        "0.0000000298023223876953125", "0.0000610053539276123046875",
        "1.00048828125", "1.00146484375", "12345678901234567890e-16",
        "18446744073709551616e-18"
      ]
      for token in tokens {
        let sink = try differentialCheck(
          Array(token.utf8),
          chunk: 1,
          as: Float16.self,
          oracle: Self.reference
        )
        #expect(sink.count == 1)
        #expect(sink.mismatches.isEmpty, "\(sink.mismatches)")
      }
    }

    @Test
    func `Long decimals on either side of half midpoints use exact fallback rounding`() throws {
      guard #available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) else { return }
      let cases: [(String, UInt16?)] = [
        ("0.0000000298023223876953124", 0),
        ("0.0000000298023223876953125", 0),
        ("0.0000000298023223876953126", 1),
        ("-0.0000000298023223876953124", 0x8000),
        ("-0.0000000298023223876953126", 0x8001),
        ("1.0004882812499999999999999", 0x3C00),
        ("1.0004882812500000000000000", 0x3C00),
        ("1.0004882812500000000000001", 0x3C01),
        ("1.0014648437499999999999999", 0x3C01),
        ("1.0014648437500000000000000", 0x3C02),
        ("1.0014648437500000000000001", 0x3C02),
        ("65519.99999999999999999999", 0x7BFF),
        ("65520.00000000000000000000", nil),
        ("65520.00000000000000000001", nil),
        ("6.551999999999999999999999e+4", 0x7BFF),
        ("-6.551999999999999999999999e+4", 0xFBFF),
        ("10004882812500000000000001e-25", 0x3C01)
      ]
      for (token, expected) in cases {
        let bytes = Array(token.utf8)
        let actual = bytes.withUnsafeBufferPointer { buffer in
          // Deliberately unusable magnitude: fallback must read the complete token.
          Float16(
            streamParsing: Span(_unsafeElements: buffer),
            info: NumberInfo(
              magnitude: 0,
              exponent: 0,
              digitCount: 30,
              flags: .overflowed
            )
          )
        }
        #expect(actual?.bitPattern == expected, "\(token)")
      }
    }

    @Test(arguments: ["canada.json", "mesh.json"])
    func `Half conversion matches direct half rounding on real float corpora`(name: String) throws {
      guard #available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) else { return }
      let bytes = try #require(streamBenchmarkCorpus(name))
      let sink = try differentialCheck(
        bytes,
        chunk: 4093,
        as: Float16.self,
        tracksKernel: true,
        oracle: Self.reference
      )
      #expect(sink.mismatches.isEmpty, "\(sink.mismatches)")
      #expect(sink.count > 1000)
      #expect(sink.kernelCount > sink.count / 2)
    }

    @Test
    func `Every positive half midpoint rounds correctly from long decimal tokens`() {
      // UInt128 is used only by this independent test oracle, never by conversion.
      guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) else {
        return
      }
      // Every half midpoint is an exact Double with at most 25 fractional decimal
      // places. Integer scaling supplies an independent exact expansion;
      // adding/subtracting 10^-45 puts inputs on either side while Double parsing
      // still lands on the same midpoint. Include the finite/infinity boundary.
      let decimalScale = (0..<25).reduce(UInt128(1)) { value, _ in value * 5 }
      for bits in UInt16(0)...UInt16(0x7BFF) {
        let lower = Double(Float16(bitPattern: bits))
        let upper = bits == 0x7BFF ? 65_536 : Double(Float16(bitPattern: bits + 1))
        let midpoint = (lower + upper) / 2
        let numerator = UInt128(UInt64(midpoint * 33_554_432)) * decimalScale
        let digits = String(numerator)
        var expansion = String(repeating: "0", count: max(0, 26 - digits.count)) + digits
        expansion.insert(".", at: expansion.index(expansion.endIndex, offsetBy: -25))
        let exact = Array((expansion + String(repeating: "0", count: 20)).utf8)
        var above = exact
        above[above.count - 1] = 49
        var below = exact
        var index = below.count
        while index > 0 {
          index -= 1
          if below[index] == 46 { continue }
          if below[index] != 48 {
            below[index] -= 1
            break
          }
          below[index] = 57
        }
        let next: UInt16? = bits == 0x7BFF ? nil : bits + 1
        let tie: UInt16? = bits & 1 == 0 ? bits : next
        for (bytes, expected) in [(below, Optional(bits)), (exact, tie), (above, next)] {
          let actual = bytes.withUnsafeBufferPointer { buffer in
            Float16(
              streamParsing: Span(_unsafeElements: buffer),
              info: NumberInfo(
                magnitude: 0,
                exponent: 0,
                digitCount: 50,
                flags: .overflowed
              )
            )
          }
          #expect(actual?.bitPattern == expected, "lower encoding \(bits)")
        }
      }
    }

    @Test(arguments: [1, 7, Int.max])
    func `Half scalars optional fields arrays and dictionaries parse`(chunk: Int) throws {
      guard #available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *) else { return }
      var root: Float16 = 0
      try parsePartial("3.14159265358979", into: &root, chunk: chunk)
      #expect(root.bitPattern == Float16("3.14159265358979")?.bitPattern)
      var fields = HalfFloatFields.Partial()
      try parsePartial(
        #"{"scalar":3.14159265358979,"optional":null,"array":[2049,-0,0.00001],"dictionary":{"x":2051}}"#,
        into: &fields,
        chunk: chunk
      )
      let snapshot = try #require(HalfFloatFields(streamPartial: fields))
      #expect(snapshot.scalar == root)
      #expect(snapshot.optional == nil)
      #expect(
        snapshot.array.map(\.bitPattern)
          == [Float16(2048), -Float16.zero, Float16("0.00001")!].map(\.bitPattern)
      )
      #expect(snapshot.dictionary["x"] == Float16(2052))
    }
  }
#endif

#if (arch(i386) || arch(x86_64)) && !(os(Windows) || os(Android))
  @StreamParseable
  private struct ExtendedFloatFields {
    var scalar: Float80 = 0
    var optional: Float80?
    var array: [Float80] = []
    var dictionary: [String: Float80] = [:]
  }

  @Suite
  struct `Float80 fast conversion tests` {
    @Test
    func `Public extended kernel is bit exact across the table`() {
      let result = checkFastFloatKernel(Float80.self)
      #expect(result.mismatches.isEmpty, "\(result.mismatches)")
      #expect(result.accepted > 80_000)
    }

    @Test
    func `Extended precision exact ties round to even without fallback`() throws {
      let magnitudes: [UInt64] = [
        1, 3, (1 << 63) - 1, (1 << 63) + 2, (1 << 63) + 6, UInt64.max
      ]
      for exponent in [0, 1, 23, 28, 55] {
        for magnitude in magnitudes {
          let token = "\(magnitude)e\(exponent)"
          let actual = try #require(
            Float80.streamConvertDecimal(
              magnitude: magnitude,
              exponent: exponent,
              negative: false
            )
          )
          let expected = try #require(Float80(token))
          #expect(actual.exponentBitPattern == expected.exponentBitPattern, "\(token)")
          #expect(actual.significandBitPattern == expected.significandBitPattern, "\(token)")
        }
      }
    }

    @Test
    func `Extended exponents outside the table decline and parse through fallback`() throws {
      for exponent in [-4951, -400, -343, 309, 400, 4932] {
        #expect(
          Float80.streamConvertDecimal(magnitude: 1, exponent: exponent, negative: false) == nil
        )
        let token = "1e\(exponent)"
        let sink = try differentialCheck(Array(token.utf8), chunk: 1, as: Float80.self)
        #expect(sink.mismatches.isEmpty, "\(sink.mismatches)")
      }
      let tokens = [
        "-0e4932", "-0e-4951", "2e-4951", "3.6451995318824746025e-4951",
        "3.3621031431120935063e-4932", "1.189731495357231765e4932", "1e4933",
        "18446744073709551615", "18446744073709551616", "18446744073709551617",
        "1.0000000000000000000542101086242752217003726400434970855712890625",
        "1.0000000000000000000542101086242752217003726400434970855712890626"
      ]
      for token in tokens {
        let sink = try differentialCheck(Array(token.utf8), chunk: 1, as: Float80.self)
        #expect(sink.mismatches.isEmpty, "\(sink.mismatches)")
      }
    }

    @Test(arguments: ["canada.json", "mesh.json"])
    func `Extended conversion matches the standard library on real float corpora`(name: String)
      throws
    {
      let bytes = try #require(streamBenchmarkCorpus(name))
      let sink = try differentialCheck(bytes, chunk: 4093, as: Float80.self)
      #expect(sink.mismatches.isEmpty, "\(sink.mismatches)")
      #expect(sink.count > 1000)
      #expect(sink.nilCount == 0)
    }

    @Test(arguments: [1, 7, Int.max])
    func `Extended scalars optional fields arrays and dictionaries parse`(chunk: Int) throws {
      var root: Float80 = 0
      try parsePartial("1e400", into: &root, chunk: chunk)
      #expect(root == Float80("1e400"))
      var fields = ExtendedFloatFields.Partial()
      try parsePartial(
        #"{"scalar":1e400,"optional":null,"array":[1e-400,-0,3.14159265358979],"dictionary":{"x":1e-400}}"#,
        into: &fields,
        chunk: chunk
      )
      let snapshot = try #require(ExtendedFloatFields(streamPartial: fields))
      #expect(snapshot.scalar == root)
      #expect(snapshot.optional == nil)
      #expect(snapshot.array == [Float80("1e-400")!, -Float80.zero, Float80("3.14159265358979")!])
      #expect(snapshot.array[1].sign == .minus)
      #expect(snapshot.dictionary["x"] == Float80("1e-400"))
    }
  }
#endif
