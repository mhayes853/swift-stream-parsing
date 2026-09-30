import StreamParsing
import Testing

@testable import StreamParsingCore

// A distinct format, not a typealias or a Float/Double identity recognized by the
// library. Arithmetic delegates to Float; decimal construction rounds directly
// to its seven fractional bits through BinaryFloatingPoint's logical encoding.
private struct TestBFloat16: StreamFastFloatConvertible, StreamInitializable, StreamParseableRoot {
  typealias Exponent = Int
  typealias RawExponent = UInt
  typealias RawSignificand = UInt16
  typealias FloatLiteralType = Double
  typealias Magnitude = Self
  typealias Stride = Self

  private(set) var bits: UInt16
  var value: Float { Float(bitPattern: UInt32(self.bits) << 16) }
  static let conversions = _StreamLock((fast: 0, fallback: 0))

  init(bits: UInt16) { self.bits = bits }
  init(_ value: Double) {
    let single = Float(value.magnitude)
    let encoding = single.bitPattern
    var rounded = UInt16(truncatingIfNeeded: encoding >> 16)
    if single.isNaN {
      rounded |= 0x40
    } else if single.isFinite {
      let discarded = encoding & 0xFFFF
      if discarded == 0x8000 {
        // Float can land exactly on a bfloat16 midpoint. Compare the original
        // Double so this test oracle does not introduce a second rounding.
        let lower = Double(Float(bitPattern: UInt32(rounded) << 16))
        let halfULP =
          Double(
            Float(
              sign: .plus,
              exponent: max(single.exponent, -126) - 7,
              significand: 1
            )
          ) / 2
        let midpoint = lower + halfULP
        if value.magnitude > midpoint || (value.magnitude == midpoint && rounded & 1 != 0) {
          rounded &+= 1
        }
      } else if discarded > 0x8000 {
        rounded &+= 1
      }
    }
    self.bits = rounded | (value.sign == .minus ? 0x8000 : 0)
  }
  init(_ value: Float) { self.init(Double(value)) }
  init(_ value: Int) { self.init(Double(value)) }
  init<Source: BinaryInteger>(_ value: Source) { self.init(Double(value)) }
  init?<Source: BinaryInteger>(exactly value: Source) {
    self.init(value)
    guard Source(exactly: self.value) == value else { return nil }
  }
  init<Source: BinaryFloatingPoint>(_ value: Source) { self.init(Double(value)) }
  init?<Source: BinaryFloatingPoint>(exactly value: Source) {
    self.init(value)
    guard Source(self.value) == value else { return nil }
  }
  init(floatLiteral value: Double) { self.init(value) }
  init(integerLiteral value: Int) { self.init(value) }
  init(sign: FloatingPointSign, exponent: Int, significand: Self) {
    self.init(Float(sign: sign, exponent: exponent, significand: significand.value))
  }
  init(signOf: Self, magnitudeOf: Self) {
    self.bits = (signOf.bits & 0x8000) | (magnitudeOf.bits & 0x7FFF)
  }
  init(sign: FloatingPointSign, exponentBitPattern: UInt, significandBitPattern: UInt16) {
    self.bits =
      (sign == .minus ? 0x8000 : 0)
      | (UInt16(truncatingIfNeeded: exponentBitPattern & 0xFF) << 7)
      | (significandBitPattern & 0x7F)
  }
  init?(_ text: String) {
    Self.conversions.withLock { $0.fallback += 1 }
    guard let value = Double(text) else { return nil }
    self.init(value)
  }
  var description: String { self.value.description }

  static func streamConvertDecimal(magnitude: UInt64, exponent: Int, negative: Bool) -> Self? {
    Self.conversions.withLock { $0.fast += 1 }
    // A deliberately declined token proves the public override is selected
    // through StreamNumberConvertible as well as direct/concrete initializers.
    if magnitude == 3_141_592_653, exponent == -9 { return nil }
    return streamEiselLemire(
      magnitude: magnitude,
      exponent: exponent,
      negative: negative,
      as: Self.self
    )
  }

  static var radix: Int { 2 }
  static var exponentBitCount: Int { 8 }
  static var significandBitCount: Int { 7 }
  static var nan: Self { Self(bits: 0x7FC0) }
  static var signalingNaN: Self { Self(bits: 0x7F81) }
  static var infinity: Self { Self(bits: 0x7F80) }
  static var greatestFiniteMagnitude: Self { Self(bits: 0x7F7F) }
  static var leastNormalMagnitude: Self { Self(bits: 0x0080) }
  static var leastNonzeroMagnitude: Self { Self(bits: 0x0001) }
  static var ulpOfOne: Self { Self(bits: 0x3C00) }
  static var pi: Self { Self(Double.pi) }
  var sign: FloatingPointSign { self.value.sign }
  var exponent: Int { self.value.exponent }
  var significand: Self { Self(self.value.significand) }
  var magnitude: Self { Self(bits: self.bits & 0x7FFF) }
  var exponentBitPattern: UInt { UInt((self.bits >> 7) & 0xFF) }
  var significandBitPattern: UInt16 { self.bits & 0x7F }
  var significandWidth: Int { self.value.significandWidth }
  var binade: Self { Self(self.value.binade) }
  var ulp: Self {
    if !self.isFinite { return Self(self.value.ulp) }
    if self.isZero || self.isSubnormal { return .leastNonzeroMagnitude }
    return Self(sign: .plus, exponent: self.exponent - 7, significand: 1)
  }
  var nextUp: Self {
    if self.isNaN || self == .infinity { return self }
    if self.isZero { return .leastNonzeroMagnitude }
    return Self(bits: self.sign == .minus ? self.bits &- 1 : self.bits &+ 1)
  }
  var isNormal: Bool { self.value.isNormal }
  var isFinite: Bool { self.value.isFinite }
  var isZero: Bool { self.value.isZero }
  var isSubnormal: Bool { self.value.isSubnormal }
  var isInfinite: Bool { self.value.isInfinite }
  var isNaN: Bool { self.value.isNaN }
  var isSignalingNaN: Bool { self.value.isSignalingNaN }
  var isCanonical: Bool { true }

  func isEqual(to other: Self) -> Bool { self.value.isEqual(to: other.value) }
  func isLess(than other: Self) -> Bool { self.value.isLess(than: other.value) }
  func isLessThanOrEqualTo(_ other: Self) -> Bool { self.value.isLessThanOrEqualTo(other.value) }
  func isTotallyOrdered(belowOrEqualTo other: Self) -> Bool {
    self.value.isTotallyOrdered(belowOrEqualTo: other.value)
  }
  func distance(to other: Self) -> Self { other - self }
  func advanced(by amount: Self) -> Self { self + amount }
  static prefix func - (value: Self) -> Self { Self(bits: value.bits ^ 0x8000) }
  mutating func negate() { self.bits ^= 0x8000 }
  func hash(into hasher: inout Hasher) { self.value.hash(into: &hasher) }
  static func + (lhs: Self, rhs: Self) -> Self { Self(lhs.value + rhs.value) }
  static func - (lhs: Self, rhs: Self) -> Self { Self(lhs.value - rhs.value) }
  static func * (lhs: Self, rhs: Self) -> Self { Self(lhs.value * rhs.value) }
  static func / (lhs: Self, rhs: Self) -> Self { Self(lhs.value / rhs.value) }
  static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
  static func -= (lhs: inout Self, rhs: Self) { lhs = lhs - rhs }
  static func *= (lhs: inout Self, rhs: Self) { lhs = lhs * rhs }
  static func /= (lhs: inout Self, rhs: Self) { lhs = lhs / rhs }
  mutating func round(_ rule: FloatingPointRoundingRule) { self = Self(self.value.rounded(rule)) }
  mutating func formRemainder(dividingBy other: Self) {
    self = Self(self.value.remainder(dividingBy: other.value))
  }
  mutating func formTruncatingRemainder(dividingBy other: Self) {
    self = Self(self.value.truncatingRemainder(dividingBy: other.value))
  }
  mutating func formSquareRoot() { self = Self(self.value.squareRoot()) }
  mutating func addProduct(_ lhs: Self, _ rhs: Self) {
    self = Self(self.value.addingProduct(lhs.value, rhs.value))
  }
}

@Suite(.serialized)
struct `Custom fast float tests` {
  @Test
  func `Custom bfloat16 precision is rounded directly by the generic kernel`() throws {
    let cases: [(UInt64, Int, UInt16)] = [
      (3_141_592_654, -9, 0x4049), (12_345_678_901, -9, 0x4146),
      (1, -40, 0x0001), (1, -41, 0), (1, 38, 0x7E96)
    ]
    for (magnitude, exponent, bits) in cases {
      // These cases require the kernel, so fallback cannot conceal narrowing.
      let actual = try #require(
        TestBFloat16.streamConvertDecimal(
          magnitude: magnitude,
          exponent: exponent,
          negative: false
        )
      )
      #expect(actual.bits == bits)
    }
  }

  @Test
  func `A public override is selected through the number conversion witness`() throws {
    TestBFloat16.conversions.withLock { $0 = (0, 0) }
    var value: TestBFloat16 = 0
    try parsePartial("3.141592653", into: &value, chunk: 1)
    #expect(value.bits == 0x4049)
    let counts = TestBFloat16.conversions.withLock { $0 }
    #expect(counts.fast == 1)
    #expect(counts.fallback == 1)
  }

  @Test
  func `An overflowed accumulator bypasses the public hook`() throws {
    TestBFloat16.conversions.withLock { $0 = (0, 0) }
    var value: TestBFloat16 = 0
    try parsePartial("314159265358979323846e-20", into: &value, chunk: 1)
    #expect(value.bits == 0x4049)
    let counts = TestBFloat16.conversions.withLock { $0 }
    #expect(counts.fast == 0)
    #expect(counts.fallback == 1)
  }

  @Test
  func `Custom exact and halfway values parse through arrays`() throws {
    var values = StreamArray<TestBFloat16>()
    try parsePartial("[1.25,257,259,-0,1e-40]", into: &values, chunk: 1)
    #expect(values.map(\.bits) == [0x3FA0, 0x4380, 0x4382, 0x8000, 0x0001])
  }
}
