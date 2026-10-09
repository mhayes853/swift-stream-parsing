import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

@StreamParseable
private struct OptionalNumberVectors: Equatable {
  var pairs: [SIMD2<Float>?] = []
  var triples: [SIMD3<Int32>?] = []
  var quads: [String: SIMD4<Float>?] = [:]
  var nested: [[SIMD2<Int>?]] = []
}

// A non-`Double` SIMD vector has no closed optional route, so an optional element of one must
// keep the vector's own lane route: that route is what makes the frame count lanes. Without it
// every lane found no slot and the element silently stayed zero.
@Suite
struct `Optional SIMD element tests` {
  @Test(arguments: [Int.max, 7, 1])
  func `Optional number vectors in containers keep their lanes`(chunk: Int) throws {
    var value = OptionalNumberVectors.Partial()
    try parsePartial(
      #"""
      {"pairs":[[0.5,1],null,[-2,3.25]],"triples":[null,[1,-2,3]],
       "quads":{"a":[1,2,3,4],"b":null},"nested":[[[1,2],null],[],[null,[3,4]]]}
      """#,
      into: &value, chunk: chunk
    )
    expectNoDifference(value.pairs.map(Array.init), [SIMD2(0.5, 1), nil, SIMD2(-2, 3.25)])
    expectNoDifference(value.triples.map(Array.init), [nil, SIMD3(1, -2, 3)])
    expectNoDifference(value.quads?["a"], .some(SIMD4(1, 2, 3, 4)))
    expectNoDifference(value.quads?["b"], .some(nil))
    expectNoDifference(
      value.nested.map { $0.map(Array.init) }, [[SIMD2(1, 2), nil], [], [nil, SIMD2(3, 4)]]
    )
  }

  @Test(arguments: [Int.max, 7, 1])
  func `Optional number vector roots keep their lanes`(chunk: Int) throws {
    var array = StreamArray<SIMD2<Float>?>()
    try parsePartial("[[0.5,1],null]", into: &array, chunk: chunk)
    expectNoDifference(Array(array), [SIMD2(0.5, 1), nil])

    var dictionary = StreamDictionary<SIMD3<Int>?>()
    try parsePartial(#"{"a":[1,2,3],"b":null}"#, into: &dictionary, chunk: chunk)
    expectNoDifference(dictionary["a"], .some(SIMD3(1, 2, 3)))
    expectNoDifference(dictionary["b"], .some(nil))
  }

  @Test(arguments: [Int.max, 1])
  func `A wrong arity optional number vector is a mismatch`(chunk: Int) {
    for json in [#"{"pairs":[[1]]}"#, #"{"pairs":[[1,2,3]]}"#, #"{"quads":{"a":[1,2,3]}}"#] {
      expectNoDifference(
        streamFailureReason(json, as: OptionalNumberVectors.Partial.self, chunk: chunk),
        .typeMismatch,
        "\(json)"
      )
    }
  }
}
