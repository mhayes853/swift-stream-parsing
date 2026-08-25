import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// The convenience layer through the windowed path, where number runs arrive as batches and
// arrays of numbers take the bulk appender: the resulting values, partial snapshots and
// errors must be what the one-at-a-time path produces.
@Suite
struct `Number batch layer tests` {
  private static func parse<Value: StreamParseableRoot>(
    _ json: String, as type: Value.Type, windowed: Bool
  ) throws -> Value {
    var stream = PartialsStream(
      initialValue: Value.streamInitialValue(),
      from: .json(windowThreshold: windowed ? 1 : .max)
    )
    try stream.next(Array(json.utf8))
    return try stream.finish()
  }

  private static func failure<Value: StreamParseableRoot>(
    _ json: String, as type: Value.Type, windowed: Bool
  ) -> JSONParsingError? {
    do {
      _ = try Self.parse(json, as: Value.self, windowed: windowed)
      return nil
    } catch let error as JSONParsingError {
      return error
    } catch {
      return nil
    }
  }

  @Test
  func `Arrays of doubles and integers match the unbatched values`() throws {
    let doubles = "[" + (0..<1000).map { "\($0).\(String(repeating: "7", count: $0 % 17 + 1))" }.joined(separator: ",") + "]"
    let a = try Self.parse(doubles, as: StreamArray<Double>.self, windowed: true)
    let b = try Self.parse(doubles, as: StreamArray<Double>.self, windowed: false)
    expectNoDifference(Array(a), Array(b))
    expectNoDifference(a.count, 1000)

    let ints = "[" + (0..<1000).map { "\($0 * 1_000_003)" }.joined(separator: ",") + "]"
    let c = try Self.parse(ints, as: StreamArray<Int>.self, windowed: true)
    let d = try Self.parse(ints, as: StreamArray<Int>.self, windowed: false)
    expectNoDifference(Array(c), Array(d))

    let nested = "[" + (0..<300).map { "[\($0).5,-\($0)e2,\($0)]" }.joined(separator: ",") + "]"
    let e = try Self.parse(nested, as: StreamArray<StreamArray<Double>>.self, windowed: true)
    let f = try Self.parse(nested, as: StreamArray<StreamArray<Double>>.self, windowed: false)
    expectNoDifference(e.map { Array($0) }, f.map { Array($0) })

    // Optional elements have no bulk appender and take the unrolled path.
    let optionals = "[1,null,3,null,5]"
    let g = try Self.parse(optionals, as: StreamArray<Int?>.self, windowed: true)
    expectNoDifference(Array(g), [1, nil, 3, nil, 5])
  }

  @Test
  func `A partial snapshot mid-array is identical`() throws {
    let json = "[" + (0..<200).map { "\($0)" }.joined(separator: ",")   // no closing bracket
    var windowed = PartialsStream(initialValue: StreamArray<Int>(), from: .json(windowThreshold: 1))
    var plain = PartialsStream(initialValue: StreamArray<Int>(), from: .json())
    try windowed.next(Array(json.utf8))
    try plain.next(Array(json.utf8))
    expectNoDifference(Array(windowed.current), Array(plain.current))
    // The last number is cut by the chunk's end and buffered, not yet emitted, on both paths.
    expectNoDifference(windowed.current.count, 199)
  }

  @Test
  func `Rejections surface as the same error`() {
    // An integer array refusing a fraction, at the element the unbatched path refuses it.
    let mixed = "[1,2,3,4.5,6]"
    expectNoDifference(
      Self.failure(mixed, as: StreamArray<Int>.self, windowed: true),
      Self.failure(mixed, as: StreamArray<Int>.self, windowed: false)
    )
    #expect(Self.failure(mixed, as: StreamArray<Int>.self, windowed: true) != nil)
    let overflow = "[" + (0..<100).map { "\($0)" }.joined(separator: ",") + ",99999999999999999999]"
    expectNoDifference(
      Self.failure(overflow, as: StreamArray<Int>.self, windowed: true),
      Self.failure(overflow, as: StreamArray<Int>.self, windowed: false)
    )
  }
}
