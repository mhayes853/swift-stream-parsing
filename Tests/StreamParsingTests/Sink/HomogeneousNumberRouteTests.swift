import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// `PartialSink.number` finishes a `[Double]` or `[Int]` element, or a `SIMD2/3/4<Double>` lane,
// itself when the token converts exactly and the slot is ready, and hands everything else to the
// outlined full path. These pin that the two halves agree: every value is the one the standard
// library parses, at every chunk cut (which moves tokens into the parser's buffer and block seals
// across parse calls), and the refusals -- out of range, not an integer, too many or too few lanes
// -- are the same failures as before the split.

@StreamParseable
private struct HomogeneousNumbers: Equatable {
  var doubles: [Double] = []
  var ints: [Int] = []
  var pairs: [SIMD2<Double>] = []
  var triples: [SIMD3<Double>] = []
  var quads: [SIMD4<Double>] = []
}

@Suite
struct `Homogeneous number route tests` {
  // Clinger-exact, past 2^53 (Eisel-Lemire), and overflowed (the string fallback) tokens mixed, so
  // consecutive elements alternate between the call-free path and the full one.
  private static let doubleTokens = [
    "0", "-0", "1", "-2.5", "0.0636837780476", "-65.613616999999977", "43.420273000000009",
    "-65.625", "9007199254740992", "9007199254740993", "1e22", "1e23", "-1e-22", "1e-23",
    "123456789012345678901234", "5e-324", "1.7976931348623157e308", "2.2250738585072014e-308",
  ]

  private static let intTokens = [
    "0", "-0", "1", "-1", "9223372036854775807", "-9223372036854775808", "4294967296", "-42",
  ]

  @Test(arguments: [Int.max, 1, 3, 7, 64])
  func `Elements and lanes hold what the standard library parses`(chunk: Int) throws {
    // Enough elements to seal several 256-slot `Double` blocks and grow the first tail.
    var doubles = [String]()
    for index in 0..<700 { doubles.append(Self.doubleTokens[index % Self.doubleTokens.count]) }
    var ints = [String]()
    for index in 0..<600 { ints.append(Self.intTokens[index % Self.intTokens.count]) }
    let lanes = Self.doubleTokens
    let pairs = (0..<300).map { "[\(lanes[$0 % lanes.count]),\(lanes[($0 + 5) % lanes.count])]" }
    let triples = (0..<40).map {
      "[\(lanes[$0 % lanes.count]),\(lanes[($0 + 1) % lanes.count]),\(lanes[($0 + 2) % lanes.count])]"
    }
    let quads = (0..<40).map { index in
      "[" + (0..<4).map { lanes[(index + $0 * 3) % lanes.count] }.joined(separator: ",") + "]"
    }
    let json = """
      {"doubles":[\(doubles.joined(separator: ","))],"ints":[\(ints.joined(separator: ", "))],
      "pairs":[\(pairs.joined(separator: ","))],"triples":[\(triples.joined(separator: ","))],
      "quads":[\(quads.joined(separator: ","))]}
      """

    var value = HomogeneousNumbers.Partial()
    try parsePartial(json, into: &value, chunk: chunk)

    let lane = { (index: Int) in Double(lanes[index % lanes.count])! }
    expectNoDifference(value.doubles.map(Array.init), doubles.map { Double($0)! })
    expectNoDifference(value.ints.map(Array.init), ints.map { Int($0)! })
    expectNoDifference(
      value.pairs.map(Array.init), (0..<300).map { SIMD2(lane($0), lane($0 + 5)) }
    )
    expectNoDifference(
      value.triples.map(Array.init), (0..<40).map { SIMD3(lane($0), lane($0 + 1), lane($0 + 2)) }
    )
    expectNoDifference(
      value.quads.map(Array.init),
      (0..<40).map { SIMD4(lane($0), lane($0 + 3), lane($0 + 6), lane($0 + 9)) }
    )
    // Bit patterns, so `-0` is not passed off as `0`.
    expectNoDifference(
      value.doubles.map { Array($0).map(\.bitPattern) },
      doubles.map { Double($0)!.bitPattern }
    )
  }

  @Test(arguments: [Int.max, 1, 2])
  func `Refused tokens fail the same way on either half`(chunk: Int) {
    let refused: [(String, StreamSinkFailure.Reason?)] = [
      (#"{"ints":[9223372036854775808]}"#, .typeMismatch),
      (#"{"ints":[-9223372036854775809]}"#, .typeMismatch),
      (#"{"ints":[1,123456789012345678901234]}"#, .typeMismatch),
      (#"{"ints":[1.0]}"#, .typeMismatch),
      (#"{"ints":[1e0]}"#, .typeMismatch),
      (#"{"doubles":[1,1e400]}"#, .typeMismatch),
      (#"{"doubles":[-1e400]}"#, .typeMismatch),
      (#"{"pairs":[[1,2,3]]}"#, .typeMismatch),
      (#"{"pairs":[[1.5,2.123456789012345678]]}"#, nil),
      (#"{"pairs":[[1]]}"#, .typeMismatch),
      (#"{"pairs":[[1,1e400]]}"#, .typeMismatch),
      (#"{"pairs":[[1,"a"]]}"#, .typeMismatch),
      (#"{"pairs":[[1,2],[3,4,5.123456789012345678]]}"#, .typeMismatch),
      (#"{"triples":[[1,2,3,4]]}"#, .typeMismatch),
      (#"{"quads":[[1,2,3]]}"#, .typeMismatch),
    ]
    for (json, reason) in refused {
      expectNoDifference(
        streamFailureReason(json, as: HomogeneousNumbers.Partial.self, chunk: chunk), reason,
        "\(json) at chunk \(chunk)"
      )
    }
  }
}
