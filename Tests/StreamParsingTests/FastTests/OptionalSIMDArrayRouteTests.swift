import CustomDump
import Testing

import StreamParsing
@testable import StreamParsingCore

@StreamParseable
private struct OptionalSIMDArrays: Equatable {
  var pairs: [SIMD2<Double>?] = []
  var triples: [SIMD3<Double>?]? = nil
  var quads: [SIMD4<Double>?] = []
  var nested: [[SIMD2<Double>?]] = []
  var optionalArray: [SIMD2<Double>]? = nil
  // Controls: element shapes with no closed route must stay generic.
  var floatPairs: [SIMD2<Float>?] = []
  var points: [OptionalSIMDPoint?] = []
  var lists: [[Double]?] = []
  var maps: [[String: Int]?] = []
}

@StreamParseable
private struct OptionalSIMDPoint: Equatable {
  var x: Double = 0
}

// An array of optional SIMD vectors takes the same closed lane-store route as a root
// `StreamArray<SIMD2<Double>?>`, whichever builder made its schema; every other non-scalar
// optional element stays on the generic route.
@Suite
struct `Optional SIMD array route tests` {
  private func route(_ key: String) -> _StreamLeafRoute? {
    OptionalSIMDArrays.Partial.streamFields
      .first { String(decoding: $0.key, as: UTF8.self) == key }?.schema?.leafRoute
  }

  @Test
  func `The optional-element array builder keeps the SIMD Double routes`() {
    expectNoDifference(
      _streamOptionalArraySchema(SIMD2<Double>.self, element: SIMD2<Double>.streamSchema).leafRoute,
      .arrayOptionalSIMD2Double
    )
    expectNoDifference(
      _streamOptionalArraySchema(SIMD3<Double>.self, element: SIMD3<Double>.streamSchema).leafRoute,
      .arrayOptionalSIMD3Double
    )
    expectNoDifference(
      _streamOptionalArraySchema(SIMD4<Double>.self, element: SIMD4<Double>.streamSchema).leafRoute,
      .arrayOptionalSIMD4Double
    )
  }

  @Test
  func `Macro members pick the closed route only where one exists`() {
    expectNoDifference(self.route("pairs"), .arrayOptionalSIMD2Double)
    expectNoDifference(self.route("triples"), .arrayOptionalSIMD3Double)
    expectNoDifference(self.route("quads"), .arrayOptionalSIMD4Double)
    expectNoDifference(self.route("optionalArray"), .arraySIMD2Double)
    expectNoDifference(self.route("nested"), .generic)
    expectNoDifference(
      OptionalSIMDArrays.Partial.streamFields
        .first { String(decoding: $0.key, as: UTF8.self) == "nested" }?
        .schema?.elementSchema?.leafRoute,
      .arrayOptionalSIMD2Double
    )
    expectNoDifference(self.route("floatPairs"), .generic)
    expectNoDifference(self.route("points"), .generic)
    expectNoDifference(self.route("lists"), .generic)
    expectNoDifference(self.route("maps"), .generic)
  }

  @Test(arguments: [Int.max, 7, 1])
  func `Present, null and nested optional SIMD elements parse`(chunk: Int) throws {
    var value = OptionalSIMDArrays.Partial()
    try parsePartial(
      #"""
      {"pairs":[[1,2],null,[3.5,-4]],"triples":[null,[1,2,3]],"quads":[[1,2,3,4],null],
       "nested":[[[1,2],null],[],[null,[5,6]]],"optionalArray":[[7,8]],
       "points":[{"x":1},null],"lists":[[1.5],null],"maps":[{"a":1},null]}
      """#,
      into: &value, chunk: chunk
    )
    expectNoDifference(value.pairs.map(Array.init), [SIMD2(1, 2), nil, SIMD2(3.5, -4)])
    expectNoDifference(value.triples.map(Array.init), [nil, SIMD3(1, 2, 3)])
    expectNoDifference(value.quads.map(Array.init), [SIMD4(1, 2, 3, 4), nil])
    expectNoDifference(
      value.nested.map { $0.map(Array.init) }, [[SIMD2(1, 2), nil], [], [nil, SIMD2(5, 6)]]
    )
    expectNoDifference(value.optionalArray.map(Array.init), [SIMD2(7, 8)])
    expectNoDifference(value.points?.map { $0?.x }, [1, nil])
    expectNoDifference(value.lists?.map { $0.map(Array.init) }, [[1.5], nil])
    expectNoDifference(value.maps?.map { $0?["a"] }, [1, nil])
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A null or empty optional SIMD array member parses`(chunk: Int) throws {
    var value = OptionalSIMDArrays.Partial()
    try parsePartial(
      #"{"pairs":[],"triples":[[1,2,3]],"triples":null,"quads":[null]}"#, into: &value,
      chunk: chunk
    )
    expectNoDifference(value.pairs.map(Array.init), [])
    #expect(value.triples == nil)
    expectNoDifference(value.quads.map(Array.init), [nil])
  }

  @Test(arguments: [Int.max, 1])
  func `A malformed optional SIMD element is a mismatch`(chunk: Int) {
    for json in [
      #"{"pairs":[[1]]}"#, #"{"pairs":[[1,2,3]]}"#, #"{"pairs":[1]}"#, #"{"pairs":["x"]}"#,
      #"{"pairs":[{"x":1}]}"#, #"{"pairs":[[null,1]]}"#, #"{"pairs":[[true,1]]}"#,
    ] {
      expectNoDifference(
        streamFailureReason(json, as: OptionalSIMDArrays.Partial.self, chunk: chunk),
        .typeMismatch,
        "\(json)"
      )
    }
  }
}
