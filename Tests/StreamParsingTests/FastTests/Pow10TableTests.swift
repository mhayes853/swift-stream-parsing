import Testing

@testable import StreamParsingCore

@Suite
struct `Pow 10 table tests` {
  // The table is generated C, so the value that matters is its bit pattern, not its
  // approximation: every entry has to be the correctly rounded `Double` for that power of ten.
  // The standard library's parser is the oracle, since it is independent of how the table was
  // emitted.
  @Test
  func `Every Entry Is The Correctly Rounded Power Of Ten`() {
    for exponent in -324...308 {
      let expected = Double("1e\(exponent)")!
      let actual = digitPow10Value(exponent)
      #expect(actual?.bitPattern == expected.bitPattern, "10^\(exponent)")
    }
  }

  @Test
  func `Exponents Outside The Table Decline`() {
    #expect(digitPow10Value(309) == nil)
    #expect(digitPow10Value(-325) == nil)
    #expect(digitPow10Value(Int.max) == nil)
    #expect(digitPow10Value(Int.min) == nil)
  }
}
