import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// Arrays of numbers through the convenience layer, bulk and chunked: payloads long enough that
// the structural block walk takes them, held to values computed without the parser.
@Suite
struct `Number array layer tests` {
  private static func parse<Value: StreamParseableRoot>(
    _ json: String, as type: Value.Type
  ) throws -> Value {
    var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
    try stream.next(Array(json.utf8))
    return try stream.finish()
  }

  private static func failure<Value: StreamParseableRoot>(
    _ json: String, as type: Value.Type
  ) -> JSONParsingError? {
    do {
      _ = try Self.parse(json, as: Value.self)
      return nil
    } catch let error as JSONParsingError {
      return error
    } catch {
      return nil
    }
  }

  // Order, not just contents: an array of numbers is the one shape where a commit can land on
  // the wrong side of the open element. Chunk sizes across and around the number width put the
  // resume in every position within a number.
  @Test(arguments: [1, 2, 3, 5, 7, 8, 11, 13, 16, 23, 32, 64, 100, 257])
  func `Chunked doubles keep their order`(chunk: Int) throws {
    let json = "[" + (0..<200).map { "\($0).5" }.joined(separator: ",") + "]"
    var stream = PartialsStream(
      initialValue: StreamArray<Double>.streamInitialValue(), from: .json()
    )
    let bytes = Array(json.utf8)
    var index = 0
    while index < bytes.count {
      let end = Swift.min(index + chunk, bytes.count)
      try stream.next(Array(bytes[index..<end]))
      index = end
    }
    let parsed = try stream.finish()

    expectNoDifference(Array(parsed), (0..<200).map { Double($0) + 0.5 }, "chunk \(chunk)")
  }

  @Test(arguments: [",", ", ", " ,\n  "])
  func `Arrays of doubles and integers hold the values their text names`(
    separator: String
  ) throws {
    let doubleTexts = (0..<1000).map { "\($0).\(String(repeating: "7", count: $0 % 17 + 1))" }
    let doubles = "[" + doubleTexts.joined(separator: separator) + "]"
    let a = try Self.parse(doubles, as: StreamArray<Double>.self)
    expectNoDifference(Array(a), doubleTexts.map { Double($0)! })

    let ints = "[" + (0..<1000).map { "\($0 * 1_000_003)" }.joined(separator: separator) + "]"
    let c = try Self.parse(ints, as: StreamArray<Int>.self)
    expectNoDifference(Array(c), (0..<1000).map { $0 * 1_000_003 })

    let nested =
      "[" + (0..<300).map { "[\($0).5,-\($0)e2,\($0)]" }.joined(separator: separator) + "]"
    let e = try Self.parse(nested, as: StreamArray<StreamArray<Double>>.self)
    expectNoDifference(
      e.map { Array($0) },
      (0..<300).map { [Double($0) + 0.5, -Double($0) * 100, Double($0)] }
    )

    let optionals = "[1,null,3,null,5]"
    let g = try Self.parse(optionals, as: StreamArray<Int?>.self)
    expectNoDifference(Array(g), [1, nil, 3, nil, 5])
  }

  @Test
  func `A partial snapshot mid-array holds every finished number`() throws {
    let json = "[" + (0..<200).map { "\($0)" }.joined(separator: ",")  // no closing bracket
    var stream = PartialsStream(initialValue: StreamArray<Int>(), from: .json())
    try stream.next(Array(json.utf8))
    // The last number is cut by the chunk's end and buffered, not yet emitted.
    expectNoDifference(Array(stream.current), Array(0..<199))
  }

  @Test
  func `Rejections surface at the element that causes them`() {
    // An integer array refusing a fraction.
    let mixed = "[" + (0..<100).map { "\($0)" }.joined(separator: ",") + ",4.5,6]"
    #expect(Self.failure(mixed, as: StreamArray<Int>.self) != nil)
    let overflow = "[" + (0..<100).map { "\($0)" }.joined(separator: ",") + ",99999999999999999999]"
    #expect(Self.failure(overflow, as: StreamArray<Int>.self) != nil)
  }
}
