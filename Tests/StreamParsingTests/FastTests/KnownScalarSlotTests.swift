import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// Scalars that reach an array element, a dictionary value, a SIMD lane or an `InlineArray` slot
// of a kind the library knows are written by a typed store at the slot, with no schema closure
// in between. These pin every such kind end to end, alongside the routes that still go through
// the closures (a custom scalar), so the two agree on values, nulls and refusals.

@StreamParseable
private struct KindContainers: Equatable {
  var bytes: [Int8] = []
  var shorts: [UInt16] = []
  var singles: [Float] = []
  var maybeInts: [Int32?] = []
  var byName: [String: Int8] = [:]
  var ratios: [String: Float] = [:]
  var maybeByName: [String: Int64?] = [:]
  var flagsByName: [String: Bool?] = [:]
  var direction: SIMD3<Float> = .zero
  var lanes: SIMD4<Int32> = .zero
  var origin: SIMD2<Double>? = nil
  var directions: [SIMD3<Float>] = []
}

// A scalar the library has no layout for: it must still arrive through the closures.
private struct Celsius: StreamNumberConvertible, StreamInitializable, Equatable {
  var degrees: Double
  static func streamInitialValue() -> Self { Self(degrees: 0) }
  init(degrees: Double) { self.degrees = degrees }
  init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = Double(streamParsing: bytes, info: info) else { return nil }
    self.degrees = value
  }
}

extension Celsius: StreamParseable, StreamParseableRoot {
  typealias Partial = Self
}

@StreamParseable
private struct CustomContainers: Equatable {
  var readings: [Celsius] = []
  var byName: [String: Celsius] = [:]
}

@Suite
struct KnownScalarSlotTests {
  private func failure<Root: StreamParseableRoot>(
    _ json: String, as type: Root.Type
  ) -> StreamSinkFailure.Reason? {
    var value = Root.streamInitialValue()
    do {
      try parsePartial(json, into: &value)
      return nil
    } catch let error as JSONParsingError {
      guard case .sinkRejectedToken(let failure) = error.reason else { return nil }
      return failure.reason
    } catch {
      return nil
    }
  }

  @Test(arguments: [Int.max, 5, 1])
  func `Every known kind lands in its slot`(chunk: Int) throws {
    var value = KindContainers.Partial()
    try parsePartial(
      #"""
      {"bytes":[-1,127,-128],"shorts":[65535,0],"singles":[0.5,-2.25],
       "maybeInts":[1,null,3],"byName":{"a":-5,"b":6},"ratios":{"x":1.5},
       "maybeByName":{"p":9,"q":null},"flagsByName":{"t":true,"n":null},
       "direction":[1.5,-2,3],"lanes":[1,2,3,4],"origin":[0.25,0.75],
       "directions":[[1,2,3],[4,5,6]]}
      """#,
      into: &value, chunk: chunk
    )
    expectNoDifference(value.bytes.map(Array.init), [-1, 127, -128])
    expectNoDifference(value.shorts.map(Array.init), [65535, 0])
    expectNoDifference(value.singles.map(Array.init), [0.5, -2.25])
    expectNoDifference(value.maybeInts.map(Array.init), [1, nil, 3])
    expectNoDifference(value.byName?["a"], -5)
    expectNoDifference(value.byName?["b"], 6)
    expectNoDifference(value.ratios?["x"], 1.5)
    expectNoDifference(value.maybeByName?["p"], 9)
    expectNoDifference(value.maybeByName?["q"], .some(nil))
    expectNoDifference(value.flagsByName?["t"], true)
    expectNoDifference(value.flagsByName?["n"], .some(nil))
    expectNoDifference(value.direction, SIMD3<Float>(1.5, -2, 3))
    expectNoDifference(value.lanes, SIMD4<Int32>(1, 2, 3, 4))
    expectNoDifference(value.origin, SIMD2<Double>(0.25, 0.75))
    expectNoDifference(
      value.directions.map(Array.init), [SIMD3<Float>(1, 2, 3), SIMD3<Float>(4, 5, 6)]
    )
  }

  @Test
  func `A custom scalar still arrives through its own conversion`() throws {
    var value = CustomContainers.Partial()
    try parsePartial(#"{"readings":[21.5,-3],"byName":{"k":4.25}}"#, into: &value)
    expectNoDifference(value.readings.map { $0.map(\.degrees) }, [21.5, -3])
    expectNoDifference(value.byName?["k"]?.degrees, 4.25)
  }

  @Test
  func `A token of the wrong kind is a mismatch at the slot`() {
    expectNoDifference(
      self.failure(#"{"bytes":["x"]}"#, as: KindContainers.Partial.self), .typeMismatch
    )
    expectNoDifference(
      self.failure(#"{"bytes":[128]}"#, as: KindContainers.Partial.self), .typeMismatch
    )
    expectNoDifference(
      self.failure(#"{"byName":{"a":true}}"#, as: KindContainers.Partial.self), .typeMismatch
    )
    expectNoDifference(
      self.failure(#"{"shorts":[null]}"#, as: KindContainers.Partial.self), .typeMismatch
    )
    expectNoDifference(
      self.failure(#"{"direction":["a",1,2]}"#, as: KindContainers.Partial.self), .typeMismatch
    )
  }

  @Test
  func `A vector takes exactly its lanes`() {
    expectNoDifference(
      self.failure(#"{"direction":[1,2,3,4]}"#, as: KindContainers.Partial.self), .typeMismatch
    )
    expectNoDifference(
      self.failure(#"{"direction":[1,2]}"#, as: KindContainers.Partial.self), .typeMismatch
    )
    expectNoDifference(
      self.failure(#"{"lanes":[1,2,3,4.5]}"#, as: KindContainers.Partial.self), .typeMismatch
    )
  }
}
