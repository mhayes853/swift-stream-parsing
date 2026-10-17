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
    for exponent in 0...22 {
      let expected = Double("1e\(exponent)")!
      let actual = streamExactPow10(exponent)
      #expect(actual.bitPattern == expected.bitPattern, "10^\(exponent)")
    }
  }

  // The callers bound the index against this count rather than being handed an optional, so the
  // count is what has to be right: one past the last exact entry, `10^22`.
  @Test
  func `The Table Stops At The Last Exact Power Of Ten`() {
    #expect(streamExactPow10Count == 23)
    #expect(streamExactPow10(streamExactPow10Count - 1).bitPattern == Double("1e22")!.bitPattern)
    #expect(streamMaxExactPow10(Double.self) == 22)
    #expect(streamMaxExactPow10(Float.self) == 10)
  }
}
