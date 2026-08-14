import CustomDump
import Foundation
import SnapshotTesting
import StreamParsing
import Testing

@Suite
struct `JSONStreamParser tests` {
  @Suite
  struct `JSONString tests` {
    @Test
    func `Streams JSON String Characters`() throws {
      let json = "\"Blob\""
      let expected = ["", "B", "Bl", "Blo", "Blob", "Blob", "Blob"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON Empty String`() throws {
      let json = "\"\""
      let expected = ["", "", ""]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Escaped Quote`() throws {
      let json = "\"\\\"\""
      let expected = ["", "", "\"", "\"", "\""]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Escaped Backslash`() throws {
      let json = "\"\\\\\""
      let expected = ["", "", "\\", "\\", "\\"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Escaped Newline`() throws {
      let json = "\"line\\nend\""
      let expected = [
        "",
        "l",
        "li",
        "lin",
        "line",
        "line",
        "line\n",
        "line\ne",
        "line\nen",
        "line\nend",
        "line\nend",
        "line\nend"
      ]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Escaped Slash`() throws {
      let json = "\"\\/\""
      let expected = ["", "", "/", "/", "/"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Escaped Backspace`() throws {
      let json = "\"\\b\""
      let expected = ["", "", "\u{08}", "\u{08}", "\u{08}"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Escaped Form Feed`() throws {
      let json = "\"\\f\""
      let expected = ["", "", "\u{0C}", "\u{0C}", "\u{0C}"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Escaped Carriage Return`() throws {
      let json = "\"\\r\""
      let expected = ["", "", "\r", "\r", "\r"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Escaped Tab`() throws {
      let json = "\"\\t\""
      let expected = ["", "", "\t", "\t", "\t"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Emoji`() throws {
      let json = "\"😀\""
      let expected = ["", "", "", "", "😀", "😀", "😀"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Multiple Emojis`() throws {
      let json = "\"😀😃\""
      let expected = ["", "", "", "", "😀", "😀", "😀", "😀", "😀😃", "😀😃", "😀😃"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Two-Byte Character`() throws {
      let json = "\"\u{00E9}\""
      let expected = ["", "", "\u{00E9}", "\u{00E9}", "\u{00E9}"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Four-Byte NonEmoji Character`() throws {
      let json = "\"\u{1D11E}\""
      let expected = ["", "", "", "", "\u{1D11E}", "\u{1D11E}", "\u{1D11E}"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Square Brackets Inside`() throws {
      let json = "\"[]\""
      let expected = ["", "[", "[]", "[]", "[]"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String With Consecutive Four-Byte Scalars`() throws {
      let scalar1 = "\u{10437}"
      let scalar2 = "\u{10438}"
      let json = "\"\(scalar1)\(scalar2)\""
      let expected = [
        "",
        "",
        "",
        "",
        scalar1,
        scalar1,
        scalar1,
        scalar1,
        "\(scalar1)\(scalar2)",
        "\(scalar1)\(scalar2)",
        "\(scalar1)\(scalar2)"
      ]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Streams JSON String Containing Only Numbers`() throws {
      let json = "\"123\""
      let expected = ["", "1", "12", "123", "123", "123"]
      try expectJSONStreamedValues(json, initialValue: "", expected: expected)
    }

    @Test
    func `Chunked Parsing Flushes String Once Per Chunk`() throws {
      var stream = PartialsStream(
        initialValue: StringValueContainer.Partial(),
        from: .json()
      )

      try stream.next("{\"value\":\"Bl".utf8)
      let first = stream.current
      try stream.next("ob\"}".utf8)
      let second = stream.current
      let final = try stream.finish()

      expectNoDifference(first, StringValueContainer.Partial(value: "Bl"))
      expectNoDifference(second, StringValueContainer.Partial(value: "Blob"))
      expectNoDifference(final, StringValueContainer.Partial(value: "Blob"))
    }
  }

  @Suite
  struct `JSONNumber tests` {
    @Test
    func `Streams JSON Integer Digits`() throws {
      let json = "1234"
      let expected: [Swift.Int] = [1, 12, 123, 1234, 1234]
      try expectJSONStreamedValues(
        json, initialValue: 0, expected: expected
      )
    }

    @Test
    func `Streams JSON Zero Integer`() throws {
      let json = "0"
      let expected = [0, 0]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Negative Integer Digits`() throws {
      let json = "-123"
      let expected: [Swift.Int] = [0, -1, -12, -123, -123]
      try expectJSONStreamedValues(
        json, initialValue: 0, expected: expected
      )
    }

    @Test
    func `Streams JSON Double Zero With Trailing Decimal`() throws {
      let json = "0.0"
      let states: [StreamedRun<Double>] = [
        .run(0, 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: 0, states: states
      )
    }

    @Test
    func `Streams JSON Float Zero With Trailing Decimal`() throws {
      let json = "0.0"
      let states: [StreamedRun<Float>] = [
        .run(0, 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: 0, states: states
      )
    }

    @Test
    func `Streams JSON Double Digits`() throws {
      let json = "12.34"
      let expected: [Swift.Double] = [1.0, 12.0, 12.0, 12.3, 12.34, 12.34]
      try expectJSONStreamedValues(
        json, initialValue: 0, expected: expected
      )
    }

    @Test
    func `Streams JSON Negative Double Digits`() throws {
      let json = "-12.34"
      let expected: [Swift.Double] = [0.0, -1.0, -12.0, -12.0, -12.3, -12.34, -12.34]
      try expectJSONStreamedValues(
        json, initialValue: 0, expected: expected
      )
    }

    @Test
    func `Streams JSON Float Digits`() throws {
      let json = "12.34"
      let expected: [Swift.Float] = [1.0, 12.0, 12.0, 12.3, 12.34, 12.34]
      try expectJSONStreamedValues(
        json, initialValue: 0, expected: expected
      )
    }

    @Test
    func `Streams JSON Double Exponent Digits`() throws {
      let json = "12e3"
      let expected: [Swift.Double] = [1.0, 12.0, 12.0, 12000.0, 12000.0]
      try expectJSONStreamedValues(
        json, initialValue: 0, expected: expected
      )
    }

    @Test
    func `Streams JSON Double Negative Exponent Digits`() throws {
      let json = "12e-3"
      let states: [StreamedRun<Swift.Double>] = [
        .run(1.0),
        .run(12.0, 3),
        .run(0.012, 2)
      ]
      try expectJSONStreamedValues(
        json, initialValue: 0, states: states
      )
    }

    @Test
    func `Streams JSON Double Positive Exponent Digits`() throws {
      let json = "12e+3"
      let states: [StreamedRun<Swift.Double>] = [
        .run(1.0),
        .run(12.0, 3),
        .run(12000.0, 2)
      ]
      try expectJSONStreamedValues(
        json, initialValue: 0, states: states
      )
    }

    @Test
    func `Streams JSON Double Uppercase Exponent Digits`() throws {
      let json = "12E3"
      let expected: [Swift.Double] = [1.0, 12.0, 12.0, 12000.0, 12000.0]
      try expectJSONStreamedValues(
        json, initialValue: 0, expected: expected
      )
    }

    @Test
    func `Streams JSON Double Large Positive Exponent Digits`() throws {
      let json = "12e21"
      let expected = 1.2e22
      let values = try json.utf8.partials(initialValue: 0.0, from: .json())
      expectClose(try #require(values.last), expected, epsilon: 1e7)
    }

    @Test
    func `Streams JSON Double Large Negative Exponent Digits`() throws {
      let json = "12e-21"
      let expected = 1.2e-20
      let values = try json.utf8.partials(initialValue: 0.0, from: .json())
      expectClose(try #require(values.last), expected, epsilon: 1e-30)
    }

    @Test
    func `Streams JSON Double Positive Zero Exponent Digits`() throws {
      let json = "12e+0"
      let states: [StreamedRun<Swift.Double>] = [
        .run(1.0),
        .run(12.0, 5)
      ]
      try expectJSONStreamedValues(
        json, initialValue: 0, states: states
      )
    }

    @Test
    func `Streams JSON Double Negative Zero Exponent Digits`() throws {
      let json = "12e-0"
      let states: [StreamedRun<Swift.Double>] = [
        .run(1.0),
        .run(12.0, 5)
      ]
      try expectJSONStreamedValues(
        json, initialValue: 0, states: states
      )
    }

    @Test
    func `Streams JSON Float Exponent Digits`() throws {
      let json = "12e3"
      let expected: [Swift.Float] = [1.0, 12.0, 12.0, 12000.0, 12000.0]
      try expectJSONStreamedValues(
        json, initialValue: 0, expected: expected
      )
    }

    @Test
    func `Streams JSON Float Positive Exponent Digits`() throws {
      let json = "12e+3"
      let states: [StreamedRun<Swift.Float>] = [
        .run(1.0),
        .run(12.0, 3),
        .run(12000.0, 2)
      ]
      try expectJSONStreamedValues(
        json, initialValue: 0, states: states
      )
    }

    @Test
    func `Streams JSON Float Uppercase Exponent Digits`() throws {
      let json = "12E3"
      let expected: [Swift.Float] = [1.0, 12.0, 12.0, 12000.0, 12000.0]
      try expectJSONStreamedValues(
        json, initialValue: 0, expected: expected
      )
    }

    @Test
    func `Streams JSON Double With Trailing Decimal Zero`() throws {
      let json = "11.0"
      let states: [StreamedRun<Swift.Double>] = [
        .run(1.0),
        .run(11.0, 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: 0, states: states
      )
    }

    @Test
    func `Streams JSON Float With Trailing Decimal Zero`() throws {
      let json = "11.0"
      let states: [StreamedRun<Swift.Float>] = [
        .run(1.0),
        .run(11.0, 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: 0, states: states
      )
    }

    @Test
    func `Streams JSON Large Integer Digits`() throws {
      let json = "18446744073709551615"
      let expected: [Swift.UInt64] = [1, 18, 184, 1844, 18446, 184467, 1844674, 18446744, 184467440, 1844674407, 18446744073, 184467440737, 1844674407370, 18446744073709, 184467440737095, 1844674407370955, 18446744073709551, 184467440737095516, 1844674407370955161, 18446744073709551615, 18446744073709551615]
      try expectJSONStreamedValues(
        json, initialValue: UInt64(0), expected: expected
      )
    }

    @Test
    func `Streams JSON Large Negative Integer Digits`() throws {
      let json = "-9223372036854775807"
      let expected: [Swift.Int64] = [0, -9, -92, -922, -9223, -92233, -922337, -9223372, -92233720, -922337203, -9223372036, -92233720368, -922337203685, -9223372036854, -92233720368547, -922337203685477, -9223372036854775, -92233720368547758, -922337203685477580, -9223372036854775807, -9223372036854775807]
      try expectJSONStreamedValues(
        json, initialValue: Int64(0), expected: expected
      )
    }

    @Test
    @available(StreamParsing128BitIntegers, *)
    func `Streams JSON Large UInt128 Digits`() throws {
      let json = "340282366920938463463374607431768211455"
      let expected: [Swift.UInt128] = [3, 34, 340, 3402, 34028, 340282, 3402823, 34028236, 340282366, 3402823669, 34028236692, 340282366920, 3402823669209, 34028236692093, 340282366920938, 3402823669209384, 34028236692093846, 340282366920938463, 3402823669209384634, 34028236692093846346, 340282366920938463463, 3402823669209384634633, 34028236692093846346337, 340282366920938463463374, 3402823669209384634633746, 34028236692093846346337460, 340282366920938463463374607, 3402823669209384634633746074, 34028236692093846346337460743, 340282366920938463463374607431, 3402823669209384634633746074317, 34028236692093846346337460743176, 340282366920938463463374607431768, 3402823669209384634633746074317682, 34028236692093846346337460743176821, 340282366920938463463374607431768211, 3402823669209384634633746074317682114, 34028236692093846346337460743176821145, 340282366920938463463374607431768211455, 340282366920938463463374607431768211455]
      try expectJSONStreamedValues(
        json, initialValue: UInt128(0), expected: expected
      )
    }

    @Test
    @available(StreamParsing128BitIntegers, *)
    func `Streams JSON Large Negative Int128 Digits`() throws {
      let json = "-170141183460469231731687303715884105727"
      let expected: [Swift.Int128] = [0, -1, -17, -170, -1701, -17014, -170141, -1701411, -17014118, -170141183, -1701411834, -17014118346, -170141183460, -1701411834604, -17014118346046, -170141183460469, -1701411834604692, -17014118346046923, -170141183460469231, -1701411834604692317, -17014118346046923173, -170141183460469231731, -1701411834604692317316, -17014118346046923173168, -170141183460469231731687, -1701411834604692317316873, -17014118346046923173168730, -170141183460469231731687303, -1701411834604692317316873037, -17014118346046923173168730371, -170141183460469231731687303715, -1701411834604692317316873037158, -17014118346046923173168730371588, -170141183460469231731687303715884, -1701411834604692317316873037158841, -17014118346046923173168730371588410, -170141183460469231731687303715884105, -1701411834604692317316873037158841057, -17014118346046923173168730371588410572, -170141183460469231731687303715884105727, -170141183460469231731687303715884105727]
      try expectJSONStreamedValues(
        json, initialValue: Int128(0), expected: expected
      )
    }

    @Test
    func `Parses Double With High Precision`() throws {
      let json = "3.14159265358979323846"
      let expected: [Swift.Double] = [3.0, 3.0, 3.1, 3.14, 3.141, 3.1415, 3.14159, 3.141592, 3.1415926, 3.14159265, 3.141592653, 3.1415926535, 3.14159265358, 3.141592653589, 3.1415926535897, 3.14159265358979, 3.141592653589793, 3.141592653589793, 3.141592653589793, 3.141592653589793, 3.141592653589793, 3.141592653589793, 3.141592653589793]
      try expectJSONStreamedValues(
        json, initialValue: 0.0, expected: expected
      )
    }

    @Test
    func `Matches Foundation JSONDecoder Precision`() throws {
      let number = "3.14159265358979323846"
      let streamValues = try number.utf8.partials(
        initialValue: 0.0,
        from: .json()
      )
      let streamValue = try #require(streamValues.last)

      let foundationValue = try JSONDecoder().decode(Double.self, from: Data(number.utf8))

      expectClose(streamValue, foundationValue)
    }

    // A number reports the digits seen so far, so a chunk boundary mid-token is visible as 12 on
    // the way to 1234. Those intermediates are different numbers rather than approximations of
    // the final one, which is what the incomplete flag on each of them says.
    @Test
    func `A Number Split Across Chunks Reports The Digits So Far`() throws {
      var stream = PartialsStream(
        initialValue: IntValueContainer.Partial(),
        from: .json()
      )

      try stream.next("{\"value\":12".utf8)
      let first = stream.current
      try stream.next("34}".utf8)
      let second = stream.current
      let final = try stream.finish()

      expectNoDifference(first, IntValueContainer.Partial(value: 12))
      expectNoDifference(second, IntValueContainer.Partial(value: 1234))
      expectNoDifference(final, IntValueContainer.Partial(value: 1234))
    }
  }

  @Suite
  struct `JSONArray tests` {
    @Test
    func `Streams JSON Integer Array`() throws {
      let json = "[1,2]"
      let states: [StreamedRun<StreamArray<Swift.Int>>] = [
        .run([]),
        .run([1], 2),
        .run([1, 2], 3)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<Int>(), states: states
      )
    }

    @Test
    func `Streams JSON Integer Array With Heavy Whitespace`() throws {
      let json = "[  1    ,    2   ]"
      let states: [StreamedRun<StreamArray<Swift.Int>>] = [
        .run([], 3),
        .run([1], 10),
        .run([1, 2], 6)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<Int>(), states: states
      )
    }

    @Test
    func `Streams JSON Array With Fractional And Exponential Double`() throws {
      let json = "[12.34,12e3]"
      let expected: [StreamArray<Swift.Double>] = [[], [1.0], [12.0], [12.0], [12.3], [12.34], [12.34], [12.34, 1.0], [12.34, 12.0], [12.34, 12.0], [12.34, 12000.0], [12.34, 12000.0], [12.34, 12000.0]]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<Double>(), expected: expected
      )
    }

    @Test
    func `Streams JSON Integer 2D Array`() throws {
      let json = "[[1],[2]]"
      let states: [StreamedRun<StreamArray<StreamArray<Swift.Int>>>] = [
        .run([]),
        .run([[]]),
        .run([[1]], 3),
        .run([[1], []]),
        .run([[1], [2]], 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<StreamArray<Int>>(), states: states
      )
    }

    @Test
    func `Streams JSON String Array`() throws {
      let json = "[\"a\",\"b\"]"
      let expected: [StreamArray<String>] = [
        [],
        [""],
        ["a"],
        ["a"],
        ["a"],
        ["a", ""],
        ["a", "b"],
        ["a", "b"],
        ["a", "b"],
        ["a", "b"]
      ]
      try expectJSONStreamedValues(json, initialValue: StreamArray<String>(), expected: expected)
    }

    @Test
    func `Streams JSON String 2D Array`() throws {
      let json = "[[\"a\"],[\"b\"]]"
      let expected: [StreamArray<StreamArray<String>>] = [
        [],
        [[]],
        [[""]],
        [["a"]],
        [["a"]],
        [["a"]],
        [["a"]],
        [["a"], []],
        [["a"], [""]],
        [["a"], ["b"]],
        [["a"], ["b"]],
        [["a"], ["b"]],
        [["a"], ["b"]],
        [["a"], ["b"]]
      ]
      try expectJSONStreamedValues(json, initialValue: StreamArray<StreamArray<String>>(), expected: expected)
    }

    @Test
    func `Streams JSON Boolean Array`() throws {
      let json = "[true,false]"
      let states: [StreamedRun<StreamArray<Swift.Bool>>] = [
        .run([], 4),
        .run([true], 6),
        .run([true, false], 3)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<Bool>(), states: states
      )
    }

    @Test
    func `Streams JSON Boolean 2D Array`() throws {
      let json = "[[true],[false]]"
      let states: [StreamedRun<StreamArray<StreamArray<Swift.Bool>>>] = [
        .run([]),
        .run([[]], 4),
        .run([[true]], 3),
        .run([[true], []], 5),
        .run([[true], [false]], 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<StreamArray<Bool>>(), states: states
      )
    }

    @Test
    func `Streams JSON Optional Array`() throws {
      let json = "[1,null]"
      let states: [StreamedRun<StreamArray<Swift.Optional<Swift.Int>>>] = [
        .run([]),
        .run([1], 5),
        .run([1, nil], 3)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<Int?>(), states: states
      )
    }

    @Test
    func `Streams JSON Optional 2D Array`() throws {
      let json = "[[null],[1]]"
      let states: [StreamedRun<StreamArray<StreamArray<Swift.Optional<Swift.Int>>>>] = [
        .run([]),
        .run([[]], 4),
        .run([[nil]], 3),
        .run([[nil], []]),
        .run([[nil], [1]], 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<StreamArray<Int?>>(), states: states
      )
    }

    @Test
    func `Streams JSON Integer 3D Array Single Element`() throws {
      let json = "[[[1]]]"
      let states: [StreamedRun<StreamArray<StreamArray<StreamArray<Swift.Int>>>>] = [
        .run([]),
        .run([[]]),
        .run([[[]]]),
        .run([[[1]]], 5)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<StreamArray<StreamArray<Int>>>(), states: states
      )
    }
  }

  @Suite
  struct `JSONObject tests` {
    @Test
    func `Streams JSON Empty Object Into Dictionary`() throws {
      let json = "{}"
      let expected: [StreamDictionary<Int>] = [[:], [:], [:]]
      try expectJSONStreamedValues(json, initialValue: StreamDictionary<Int>(), expected: expected)
    }

    @Test
    func `Streams JSON Object With Single Key Into Dictionary`() throws {
      let json = "{\"single\":1}"
      let states: [StreamedRun<StreamParsingCore.StreamDictionary<Swift.Int>>] = [
        .run([:], 8),
        .run(["single": 0], 2),
        .run(["single": 1], 3)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamDictionary<Int>(), states: states
      )
    }

    @Test
    func `Streams JSON Object With Two Keys Into Dictionary`() throws {
      let json = "{\"first\":1,\"second\":2}"
      let states: [StreamedRun<StreamParsingCore.StreamDictionary<Swift.Int>>] = [
        .run([:], 7),
        .run(["first": 0], 2),
        .run(["first": 1], 9),
        .run(["first": 1, "second": 0], 2),
        .run(["first": 1, "second": 2], 3)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamDictionary<Int>(), states: states
      )
    }

    @Test
    func `Streams JSON Object With Two Keys Into StreamParseable Struct`() throws {
      let json = "{\"first\":1,\"second\":2}"
      let states: [StreamedRun<StreamParsingTests.TwoKeyObject.Partial>] = [
        .run(TwoKeyObject.Partial(first: nil, second: nil), 9),
        .run(TwoKeyObject.Partial(first: 1, second: nil), 11),
        .run(TwoKeyObject.Partial(first: 1, second: 2), 3)
      ]
      try expectJSONStreamedValues(
        json, initialValue: TwoKeyObject.Partial(), states: states
      )
    }

    @Test
    func `Continues Parsing After Ignored Key`() throws {
      let json = "{\"ignored\":\"alpha\",\"tracked\":\"beta\"}"
      let values = try json.utf8.partials(
        initialValue: TrackedOnly.Partial(),
        from: .json()
      )
      expectNoDifference(values.last, TrackedOnly.Partial(tracked: "beta"))
    }

    @Test
    func `Streams Pretty Printed JSON Object Into Dictionary`() throws {
      let json = "{\n  \"first\": 1,\n  \"second\": 2\n}"
      let states: [StreamedRun<StreamParsingCore.StreamDictionary<Swift.Int>>] = [
        .run([:], 10),
        .run(["first": 0], 3),
        .run(["first": 1], 12),
        .run(["first": 1, "second": 0], 3),
        .run(["first": 1, "second": 2], 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamDictionary<Int>(), states: states
      )
    }

    @Test
    func `Streams Nested JSON Object Into Dictionary Of Dictionaries`() throws {
      let json = "{\"outer\":{\"inner\":1}}"
      let states: [StreamedRun<StreamParsingCore.StreamDictionary<StreamParsingCore.StreamDictionary<Swift.Int>>>] = [
        .run([:], 7),
        .run(["outer": [:]], 9),
        .run(["outer": ["inner": 0]], 2),
        .run(["outer": ["inner": 1]], 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamDictionary<StreamDictionary<Int>>(), states: states
      )
    }

    @Test
    func `Streams Nested JSON Object Into StreamParseable Struct`() throws {
      let json = "{\"nested\":{\"value\":1}}"
      let states: [StreamedRun<StreamParsingTests.NestedContainer.Partial>] = [
        .run(NestedContainer.Partial(nested: nil), 10),
        .run(NestedContainer.Partial(nested: NestedValue.Partial(value: nil)), 9),
        .run(NestedContainer.Partial(nested: NestedValue.Partial(value: 1)), 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: NestedContainer.Partial(), states: states
      )
    }

    @Test
    func
      `Streams Nested JSON Object Into StreamParseable Struct With Initial Parseable Partial Members`()
      throws
    {
      let json = "{\"nested\":{\"value\":1}}"
      let states: [StreamedRun<StreamParsingTests.InitialParseableNestedContainer.Partial>] = [
        .run(InitialParseableNestedContainer.Partial(nested: InitialParseableNestedValue.Partial(value: 0)), 19),
        .run(InitialParseableNestedContainer.Partial(nested: InitialParseableNestedValue.Partial(value: 1)), 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: InitialParseableNestedContainer.Partial(), states: states
      )
    }

    @Test
    func `Streams Doubly Nested JSON Object Into Dictionary Of Dictionaries Of Dictionaries`()
      throws
    {
      let json = "{\"level1\":{\"level2\":{\"value\":1}}}"
      let states: [StreamedRun<StreamParsingCore.StreamDictionary<StreamParsingCore.StreamDictionary<StreamParsingCore.StreamDictionary<Swift.Int>>>>] = [
        .run([:], 8),
        .run(["level1": [:]], 10),
        .run(["level1": ["level2": [:]]], 9),
        .run(["level1": ["level2": ["value": 0]]], 2),
        .run(["level1": ["level2": ["value": 1]]], 5)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamDictionary<StreamDictionary<StreamDictionary<Int>>>(), states: states
      )
    }

    @Test
    func `Streams Doubly Nested JSON Object Into StreamParseable Struct`() throws {
      let json = "{\"level1\":{\"level2\":{\"value\":1}}}"
      let states: [StreamedRun<StreamParsingTests.DoubleNestedRoot.Partial>] = [
        .run(DoubleNestedRoot.Partial(level1: nil), 10),
        .run(DoubleNestedRoot.Partial(level1: DoubleNestedLevel1.Partial(level2: nil)), 10),
        .run(DoubleNestedRoot.Partial(level1: DoubleNestedLevel1.Partial(level2: DoubleNestedLevel2.Partial(value: nil))), 9),
        .run(DoubleNestedRoot.Partial(level1: DoubleNestedLevel1.Partial(level2: DoubleNestedLevel2.Partial(value: 1))), 5)
      ]
      try expectJSONStreamedValues(
        json, initialValue: DoubleNestedRoot.Partial(), states: states
      )
    }

    @Test
    func `Streams JSON Object With Fractional And Exponential Doubles Into Dictionary`() throws {
      let json = "{\"fractional\":12.34,\"exponential\":12e3}"
      let states: [StreamedRun<StreamParsingCore.StreamDictionary<Swift.Double>>] = [
        .run([:], 12),
        .run(["fractional": 0.0], 2),
        .run(["fractional": 1.0]),
        .run(["fractional": 12.0], 2),
        .run(["fractional": 12.3]),
        .run(["fractional": 12.34], 14),
        .run(["fractional": 12.34, "exponential": 0.0], 2),
        .run(["fractional": 12.34, "exponential": 1.0]),
        .run(["fractional": 12.34, "exponential": 12.0], 2),
        .run(["fractional": 12.34, "exponential": 12000.0], 3)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamDictionary<Double>(), states: states
      )
    }

    @Test
    func `Streams JSON Object With Nullable Value Into StreamParseable Struct`() throws {
      let json = "{\"maybe\":null}"
      let states: [StreamedRun<StreamParsingTests.NullableObject.Partial>] = [
        .run(NullableObject.Partial(maybe: nil), 15)
      ]
      try expectJSONStreamedValues(
        json, initialValue: NullableObject.Partial(), states: states
      )
    }

    @Test
    func `Streams JSON Object With Nested Nullable Value Into StreamParseable Struct`() throws {
      let json = "{\"inner\":{\"maybe\":null}}"
      let states: [StreamedRun<StreamParsingTests.NullableNestedContainer.Partial>] = [
        .run(NullableNestedContainer.Partial(inner: nil), 9),
        .run(NullableNestedContainer.Partial(inner: NullableNestedValue.Partial(maybe: nil)), 16)
      ]
      try expectJSONStreamedValues(
        json, initialValue: NullableNestedContainer.Partial(), states: states
      )
    }

    @Test
    func `Streams JSON Object With Nullable Value Into Dictionary`() throws {
      let json = "{\"maybe\":null}"
      let states: [StreamedRun<StreamParsingCore.StreamDictionary<Swift.Optional<Swift.Int>>>] = [
        .run([:], 7),
        .run(["maybe": nil], 8)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamDictionary<Int?>(), states: states
      )
    }

    @Test
    func `Parses Empty Object From Boolean Property`() throws {
      let json = "{\"flag\":true,\"other\":{}}"
      let values = try json.utf8.partials(
        initialValue: EmptyObject.Partial(),
        from: .json()
      )
      expectNoDifference(values.last, EmptyObject.Partial())
    }

    @Test
    func `Parses Empty Object From Null Property`() throws {
      let json = "{\"value\":null,\"other\":{}}"
      let values = try json.utf8.partials(
        initialValue: EmptyObject.Partial(),
        from: .json()
      )
      expectNoDifference(values.last, EmptyObject.Partial())
    }

    @Test
    func `Parses Empty Object From Array Property`() throws {
      let json = "{\"values\":[1,2,3],\"other\":{}}"
      let values = try json.utf8.partials(
        initialValue: EmptyObject.Partial(),
        from: .json()
      )
      expectNoDifference(values.last, EmptyObject.Partial())
    }

    @Test
    func `Streams JSON Object With Dictionary Property Into StreamParseable Struct`() throws {
      let json = "{\"values\":{\"inner\":1}}"
      let states: [StreamedRun<StreamParsingTests.DictionaryPropertyContainer.Partial>] = [
        .run(DictionaryPropertyContainer.Partial(values: nil), 23)
      ]
      try expectJSONStreamedValues(
        json, initialValue: DictionaryPropertyContainer.Partial(), states: states
      )
    }

    @Test
    func `Streams JSON Object With Array Property Into StreamParseable Struct`() throws {
      let json = "{\"numbers\":[1,2]}"
      let states: [StreamedRun<StreamParsingTests.ArrayPropertyContainer.Partial>] = [
        .run(ArrayPropertyContainer.Partial(numbers: nil), 11),
        .run(ArrayPropertyContainer.Partial(numbers: [])),
        .run(ArrayPropertyContainer.Partial(numbers: [1]), 2),
        .run(ArrayPropertyContainer.Partial(numbers: [1, 2]), 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: ArrayPropertyContainer.Partial(), states: states
      )
    }

    @Test
    func `Streams JSON Object With Nested Array Property Into StreamParseable Struct`() throws {
      let json = "{\"level1\":{\"level2\":{\"numbers\":[1,2]}}}"
      let states: [StreamedRun<StreamParsingTests.ArrayNestedRoot.Partial>] = [
        .run(ArrayNestedRoot.Partial(level1: nil), 10),
        .run(ArrayNestedRoot.Partial(level1: ArrayNestedLevel1.Partial(level2: nil)), 10),
        .run(ArrayNestedRoot.Partial(level1: ArrayNestedLevel1.Partial(level2: ArrayNestedLevel2.Partial(numbers: nil))), 11),
        .run(ArrayNestedRoot.Partial(level1: ArrayNestedLevel1.Partial(level2: ArrayNestedLevel2.Partial(numbers: [])))),
        .run(ArrayNestedRoot.Partial(level1: ArrayNestedLevel1.Partial(level2: ArrayNestedLevel2.Partial(numbers: [1]))), 2),
        .run(ArrayNestedRoot.Partial(level1: ArrayNestedLevel1.Partial(level2: ArrayNestedLevel2.Partial(numbers: [1, 2]))), 6)
      ]
      try expectJSONStreamedValues(
        json, initialValue: ArrayNestedRoot.Partial(), states: states
      )
    }

    @Test
    func `Parses Object Into Empty StreamParseable Type`() throws {
      let json = """
        {
          "bio" : "Donec lobortis eleifend condimentum. Cras dictum dolor lacinia lectus vehicula rutrum. Maecenas quis nisi nunc. Nam tristique feugiat est vitae mollis. Maecenas quis nisi nunc.",
          "id" : "V59OF92YF627HFY0",
          "language" : "Sindhi",
          "name" : "Adeel Solangi",
          "version" : 6.1
        }
        """
      var stream = PartialsStream(initialValue: EmptyObject.Partial(), from: .json())
      for byte in json.utf8 {
        try stream.next(byte)
      }
      let final = try stream.finish()
      expectNoDifference(final, EmptyObject.Partial())
    }

    @Test
    func `Streams JSON Empty Object Into StreamParseable Struct`() throws {
      let json = "{}"
      let expected = Array(repeating: EmptyObject.Partial(), count: 3)
      try expectJSONStreamedValues(json, initialValue: EmptyObject.Partial(), expected: expected)
    }

    @Test
    func `Streams JSON Object With Duplicate Keys Into Dictionary Keeping Last Value`() throws {
      let json = "{\"value\":1,\"value\":2}"
      let states: [StreamedRun<StreamParsingCore.StreamDictionary<Swift.Int>>] = [
        .run([:], 7),
        .run(["value": 0], 2),
        .run(["value": 1], 10),
        .run(["value": 2], 3)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamDictionary<Int>(), states: states
      )
    }
  }

  @Suite
  struct `JSONCombination tests` {
    @Test
    func `Streams JSON Array Of StreamParseable Structs`() throws {
      let json = "[{\"value\":1}]"
      let states: [StreamedRun<StreamArray<StreamParsingTests.CombinationItem.Partial>>] = [
        .run([]),
        .run([CombinationItem.Partial(value: nil)], 9),
        .run([CombinationItem.Partial(value: 1)], 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<CombinationItem.Partial>(), states: states
      )
    }

    @Test
    func `Streams JSON Array Of StreamParseable Structs With Multiple Elements`() throws {
      let json = "[{\"value\":1},{\"value\":2}]"
      let states: [StreamedRun<StreamArray<StreamParsingTests.CombinationItem.Partial>>] = [
        .run([]),
        .run([CombinationItem.Partial(value: nil)], 9),
        .run([CombinationItem.Partial(value: 1)], 3),
        .run([CombinationItem.Partial(value: 1), CombinationItem.Partial(value: nil)], 9),
        .run([CombinationItem.Partial(value: 1), CombinationItem.Partial(value: 2)], 4)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<CombinationItem.Partial>(), states: states
      )
    }

    @Test
    func `Streams JSON Empty Array Of StreamParseable Structs`() throws {
      let json = "[]"
      let expected = Array(repeating: StreamArray<CombinationItem.Partial>(), count: 3)
      try expectJSONStreamedValues(
        json,
        initialValue: StreamArray<CombinationItem.Partial>(),
        expected: expected
      )
    }

    @Test
    func `Streams JSON Object With Array Of StreamParseable Structs`() throws {
      let json = "{\"items\":[{\"value\":1}]}"
      let states: [StreamedRun<StreamParsingTests.CombinationContainer.Partial>] = [
        .run(CombinationContainer.Partial(items: nil), 9),
        .run(CombinationContainer.Partial(items: [])),
        .run(CombinationContainer.Partial(items: [CombinationItem.Partial(value: nil)]), 9),
        .run(CombinationContainer.Partial(items: [CombinationItem.Partial(value: 1)]), 5)
      ]
      try expectJSONStreamedValues(
        json, initialValue: CombinationContainer.Partial(), states: states
      )
    }

    @Test
    func `Streams JSON Object With Empty Array Of StreamParseable Structs`() throws {
      let json = "{\"items\":[]}"
      let beforeArray = Array(repeating: CombinationContainer.Partial(), count: 9)
      let afterArray = Array(repeating: CombinationContainer.Partial(items: []), count: 4)
      let expected = beforeArray + afterArray
      try expectJSONStreamedValues(
        json,
        initialValue: CombinationContainer.Partial(),
        expected: expected
      )
    }

    @Test
    func `Streams JSON Object With Multi-Element Array Of StreamParseable Structs`() throws {
      let json = "{\"items\":[{\"value\":1},{\"value\":2}]}"
      let states: [StreamedRun<StreamParsingTests.CombinationContainer.Partial>] = [
        .run(CombinationContainer.Partial(items: nil), 9),
        .run(CombinationContainer.Partial(items: [])),
        .run(CombinationContainer.Partial(items: [CombinationItem.Partial(value: nil)]), 9),
        .run(CombinationContainer.Partial(items: [CombinationItem.Partial(value: 1)]), 3),
        .run(CombinationContainer.Partial(items: [CombinationItem.Partial(value: 1), CombinationItem.Partial(value: nil)]), 9),
        .run(CombinationContainer.Partial(items: [CombinationItem.Partial(value: 1), CombinationItem.Partial(value: 2)]), 5)
      ]
      try expectJSONStreamedValues(
        json, initialValue: CombinationContainer.Partial(), states: states
      )
    }

    @Test
    func `Streams Quadruple Nested JSON Object Array Array Object`() throws {
      let json = "{\"matrix\":[[{\"value\":1}]]}"
      let states: [StreamedRun<StreamParsingTests.CombinationMatrixContainer.Partial>] = [
        .run(CombinationMatrixContainer.Partial(matrix: nil), 10),
        .run(CombinationMatrixContainer.Partial(matrix: [])),
        .run(CombinationMatrixContainer.Partial(matrix: [[]])),
        .run(CombinationMatrixContainer.Partial(matrix: [[CombinationMatrixItem.Partial(value: nil)]]), 9),
        .run(CombinationMatrixContainer.Partial(matrix: [[CombinationMatrixItem.Partial(value: 1)]]), 6)
      ]
      try expectJSONStreamedValues(
        json, initialValue: CombinationMatrixContainer.Partial(), states: states
      )
    }

    @Test
    func `Streams Quadruple Nested JSON Array Object Object Array`() throws {
      let json = "[{\"inner\":{\"numbers\":[1,2]}}]"
      let states: [StreamedRun<StreamArray<StreamParsingTests.QuadArrayOuter.Partial>>] = [
        .run([]),
        .run([QuadArrayOuter.Partial(inner: nil)], 9),
        .run([QuadArrayOuter.Partial(inner: QuadArrayInner.Partial(numbers: nil))], 11),
        .run([QuadArrayOuter.Partial(inner: QuadArrayInner.Partial(numbers: []))]),
        .run([QuadArrayOuter.Partial(inner: QuadArrayInner.Partial(numbers: [1]))], 2),
        .run([QuadArrayOuter.Partial(inner: QuadArrayInner.Partial(numbers: [1, 2]))], 6)
      ]
      try expectJSONStreamedValues(
        json, initialValue: StreamArray<QuadArrayOuter.Partial>(), states: states
      )
    }
  }

  @Suite
  struct `JSONError tests` {
    @Test
    func `Streams Values Before Syntax Error`() throws {
      let json = "[1,2,x]"
      let expected: [StreamArray<Int>] = [[], [1], [1], [1, 2], [1, 2]]
      expectJSONStreamedValuesBeforeError(
        json,
        initialValue: StreamArray<Int>(),
        expected: expected,
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Missing Value`() throws {
      let json = "{\"a\":}"
      try expectJSONParsingError(
        json,
        initialValue: StreamDictionary<Int>(),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Missing Colon`() throws {
      let json = "{\"a\" 1}"
      try expectJSONParsingError(
        json,
        initialValue: StreamDictionary<Int>(),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Trailing Comma In Object`() throws {
      let json = "{\"a\": 1,}"
      try expectJSONParsingError(
        json,
        initialValue: StreamDictionary<Int>(),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Trailing Comma In Array`() throws {
      let json = "[1,]"
      try expectJSONParsingError(
        json,
        initialValue: StreamArray<Int>(),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Missing Comma In Array`() throws {
      let json = "[1 2]"
      try expectJSONParsingError(
        json,
        initialValue: StreamArray<Int>(),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Unterminated String`() throws {
      let json = "\"unterminated"
      try expectJSONParsingError(
        json,
        initialValue: "",
        reason: .unterminatedString
      )
    }

    @Test
    func `Throws For Invalid Unicode Escape`() throws {
      let json = "\"\\u12\""
      try expectJSONParsingError(
        json,
        initialValue: "",
        reason: .invalidEscape
      )
    }

    @Test
    func `Throws For Missing Closing Brace`() throws {
      let json = "{\"a\": 1"
      try expectJSONParsingError(
        json,
        initialValue: StreamDictionary<Int>(),
        reason: .unterminatedContainer
      )
    }

    @Test
    func `Throws For Missing Closing Bracket`() throws {
      let json = "[1,2"
      try expectJSONParsingError(
        json,
        initialValue: StreamArray<Int>(),
        reason: .unterminatedContainer
      )
    }

    @Test
    func `Throws For Unexpected Token In Neutral Mode`() throws {
      let json = "]["
      try expectJSONParsingError(
        json,
        initialValue: StreamArray<Int>(),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Invalid Literal`() throws {
      let json = "{\"a\": tru}"
      try expectJSONParsingError(
        json,
        initialValue: StreamDictionary<Bool>(),
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Invalid Number`() throws {
      let json = "{\"a\": -}"
      try expectJSONParsingError(
        json,
        initialValue: StreamDictionary<Int>(),
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Integer Overflow`() throws {
      let json = "[18446744073709551616]"
      try expectJSONParsingError(
        json,
        initialValue: StreamArray<UInt64>(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Int32 Overflow`() throws {
      let json = "2147483648"
      try expectJSONParsingError(
        json,
        initialValue: Int32(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For UInt32 Overflow`() throws {
      let json = "4294967296"
      try expectJSONParsingError(
        json,
        initialValue: UInt32(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Int8 Overflow`() throws {
      let json = "-129"
      try expectJSONParsingError(
        json,
        initialValue: Int8(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Float Overflow`() throws {
      let json = "3.5e38"
      try expectJSONParsingError(
        json,
        initialValue: Float(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Double Overflow`() throws {
      let json = "1e400"
      try expectJSONParsingError(
        json,
        initialValue: Double(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Leading Zero`() throws {
      let json = "{\"a\": 01}"
      try expectJSONParsingError(
        json,
        initialValue: StreamDictionary<Int>(),
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Invalid Exponent`() throws {
      let json = "{\"a\": 1e}"
      try expectJSONParsingError(
        json,
        initialValue: StreamDictionary<Double>(),
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Exponent Overflow`() throws {
      let json = "1e9223372036854775808"
      try expectJSONParsingError(
        json,
        initialValue: Double(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Missing Closing Brace In Larger Payload`() throws {
      let json =
        "{\"users\":[{\"id\":1,\"name\":\"Ada\"},{\"id\":2,\"name\":\"Grace\"}],\"meta\":{\"count\":2}"
      try expectJSONParsingError(
        json,
        initialValue: LargePayload.Partial(),
        reason: .unterminatedContainer
      )
    }

    @Test
    func `Throws For Trailing Comma In Larger Array Payload`() throws {
      let json =
        "[{\"type\":\"event\",\"payload\":{\"values\":[1,2,3]}},{\"type\":\"event\",\"payload\":{\"values\":[4,5,6]}},]"
      try expectJSONParsingError(
        json,
        initialValue: StreamArray<Event.Partial>(),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For String When Expecting Integer`() throws {
      let json = "\"123\""
      try expectJSONParsingError(
        json,
        initialValue: 0,
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For String Property When Expecting Integer In Object`() throws {
      let json = "{\"value\": \"123\"}"
      try expectJSONParsingError(
        json,
        initialValue: IntValueContainer.Partial(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For String Element When Expecting Integer In Array`() throws {
      let json = "[\"123\"]"
      try expectJSONParsingError(
        json,
        initialValue: StreamArray<Int>(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Integer When Expecting Boolean`() throws {
      let json = "1"
      try expectJSONParsingError(
        json,
        initialValue: false,
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Null When Expecting Integer`() throws {
      let json = "null"
      try expectJSONParsingError(
        json,
        initialValue: 0,
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Integer When Expecting String`() throws {
      let json = "1"
      try expectJSONParsingError(
        json,
        initialValue: "",
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Integer Element When Expecting Boolean In Array`() throws {
      let json = "[1]"
      try expectJSONParsingError(
        json,
        initialValue: StreamArray<Bool>(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Null Element When Expecting Integer In Array`() throws {
      let json = "[null]"
      try expectJSONParsingError(
        json,
        initialValue: StreamArray<Int>(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Integer Element When Expecting String In Array`() throws {
      let json = "[1]"
      try expectJSONParsingError(
        json,
        initialValue: StreamArray<String>(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Integer Property When Expecting Boolean In Object`() throws {
      let json = "{\"value\": 1}"
      try expectJSONParsingError(
        json,
        initialValue: BoolValueContainer.Partial(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Integer Property When Expecting String In Object`() throws {
      let json = "{\"value\": 1}"
      try expectJSONParsingError(
        json,
        initialValue: StringValueContainer.Partial(),
        reason: .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
      )
    }

    @Test
    func `Throws For Incomplete True Literal On Finish`() throws {
      let json = "tru"
      try expectJSONParsingError(
        json,
        initialValue: false,
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Incomplete False Literal On Finish`() throws {
      let json = "fal"
      try expectJSONParsingError(
        json,
        initialValue: true,
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Incomplete Null Literal On Finish`() throws {
      let json = "nul"
      try expectJSONParsingError(
        json,
        initialValue: String?.none,
        reason: .invalidLiteral
      )
    }

  }
  @Suite
  struct `JSONBoolean tests` {
    @Test
    func `Streams JSON True`() throws {
      let json = "true"
      let states: [StreamedRun<Swift.Bool>] = [
        .run(false, 3),
        .run(true, 2)
      ]
      try expectJSONStreamedValues(
        json, initialValue: false, states: states
      )
    }

    @Test
    func `Streams JSON False`() throws {
      let json = "false"
      let states: [StreamedRun<Swift.Bool>] = [
        .run(true, 4),
        .run(false, 2)
      ]
      try expectJSONStreamedValues(
        json, initialValue: true, states: states
      )
    }
  }

  @Suite
  struct `JSONNull tests` {
    @Test
    func `Streams JSON Null`() throws {
      let json = "null"
      let states: [StreamedRun<Swift.Optional<Swift.String>>] = [
        .run("seed", 3),
        .run(nil, 2)
      ]
      try expectJSONStreamedValues(
        json, initialValue: "seed", states: states
      )
    }
  }

}

// The runs form, for sequences where most entries repeat their predecessor. The flat form below
// stays for short sequences, where spelling out every state is clearer than compressing it.
private func expectJSONStreamedValues<T: StreamParseableRoot & Equatable>(
  _ json: String,
  format: JSONStreamFormat = .json(),
  initialValue: T,
  states: [StreamedRun<T>],
  fileID: StaticString = #fileID,
  filePath: StaticString = #filePath,
  line: UInt = #line,
  column: UInt = #column
) throws {
  let values = try json.utf8.partials(initialValue: initialValue, from: format)
  if ProcessInfo.processInfo.environment["STREAM_PARSING_RECORD"] != nil {
    print("STREAM_RECORD|\(line)|\(String(reflecting: T.self))|\(swiftLiteral(values))")
    return
  }
  expectStates(
    values, states, json: json, fileID: fileID, filePath: filePath, line: line, column: column
  )
}

private func expectJSONStreamedValues<T: StreamParseableRoot & Equatable>(
  _ json: String,
  format: JSONStreamFormat = .json(),
  initialValue: T,
  expected: [T],
  file: StaticString = #fileID,
  line: UInt = #line
) throws {
  let values = try json.utf8.partials(initialValue: initialValue, from: format)
  // Recording mode, for regenerating these sequences when the parser's timing changes on
  // purpose. It skips the assertion, so it must never be set in CI.
  if ProcessInfo.processInfo.environment["STREAM_PARSING_RECORD"] != nil {
    print("STREAM_RECORD|\(line)|\(String(reflecting: T.self))|\(swiftLiteral(values))")
    return
  }
  expectNoDifference(values, expected, fileID: file, line: line)
}

private func expectJSONStreamedValuesBeforeError<T: StreamParseableRoot & Equatable>(
  _ json: String,
  format: JSONStreamFormat = .json(),
  initialValue: T,
  expected: [T],
  reason: JSONParsingError.Reason
) {
  var stream = PartialsStream(initialValue: initialValue, from: format)
  var partials = [T]()
  let thrownError = #expect(throws: JSONParsingError.self) {
    for byte in json.utf8 {
      try stream.next(byte)
      partials.append(stream.current)
    }
    _ = try stream.finish()
  }

  guard let error = thrownError else {
    Issue.record("Expected JSONParsingError to be captured.")
    return
  }
  #expect(error.reason == reason)
  expectNoDifference(partials, expected)
}

private func expectJSONParsingError<T: StreamParseableRoot>(
  _ json: String,
  format: JSONStreamFormat = .json(),
  initialValue: T,
  reason: JSONParsingError.Reason,
  byteOffset: Int? = nil
) throws {
  let thrownError = #expect(throws: JSONParsingError.self) {
    _ = try json.utf8.partials(initialValue: initialValue, from: format)
  }

  let error = try #require(thrownError)
  #expect(error.reason == reason)
  if let byteOffset {
    #expect(error.byteOffset == byteOffset)
  }
}

@StreamParseable
struct TwoKeyObject: Equatable {
  var first: Int = 0
  var second: Int = 0
}

@StreamParseable
struct TrackedOnly: Equatable {
  var tracked: String = ""
}

@StreamParseable
struct NestedValue: Equatable {
  var value: Int = 0
}

@StreamParseable
struct NestedContainer: Equatable {
  var nested: NestedValue = .init()
}

@StreamParseable(partialMembers: .streamInitialValue)
struct InitialParseableNestedValue: Equatable {
  var value: Int = 0
}

@StreamParseable(partialMembers: .streamInitialValue)
struct InitialParseableNestedContainer: Equatable {
  var nested: InitialParseableNestedValue = .init()
}

@StreamParseable
struct DoubleNestedLevel2: Equatable {
  var value: Int = 0
}

@StreamParseable
struct DoubleNestedLevel1: Equatable {
  var level2: DoubleNestedLevel2 = .init()
}

@StreamParseable
struct DoubleNestedRoot: Equatable {
  var level1: DoubleNestedLevel1 = .init()
}

@StreamParseable
struct NullableObject: Equatable {
  var maybe: Int? = 1
}

@StreamParseable
struct NullableNestedValue: Equatable {
  var maybe: Int? = 1
}

@StreamParseable
struct NullableNestedContainer: Equatable {
  var inner: NullableNestedValue = NullableNestedValue()
}

@StreamParseable
struct EmptyObject: Equatable {}

@StreamParseable
struct DictionaryPropertyContainer: Equatable {
  var values: StreamDictionary<Int>
}

@StreamParseable
struct ArrayPropertyContainer: Equatable {
  var numbers: [Int]
}

@StreamParseable
struct ArrayNestedLevel2: Equatable {
  var numbers: [Int]
}

@StreamParseable
struct ArrayNestedLevel1: Equatable {
  var level2: ArrayNestedLevel2 = .init(numbers: [])
}

@StreamParseable
struct ArrayNestedRoot: Equatable {
  var level1: ArrayNestedLevel1 = .init()
}

@StreamParseable
struct CombinationItem: Equatable {
  var value: Int = 0
}

@StreamParseable
struct CombinationContainer: Equatable {
  var items: [CombinationItem]
}

@StreamParseable
struct IntValueContainer: Equatable {
  var value: Int = 0
}

@StreamParseable
struct BoolValueContainer: Equatable {
  var value: Bool = false
}

@StreamParseable
struct StringValueContainer: Equatable {
  var value: String = ""
}

@StreamParseable
struct CombinationMatrixItem: Equatable {
  var value: Int = 0
}

@StreamParseable
struct CombinationMatrixContainer: Equatable {
  var matrix: [[CombinationMatrixItem]]
}

@StreamParseable
struct QuadArrayInner: Equatable {
  var numbers: [Int]
}

@StreamParseable
struct QuadArrayOuter: Equatable {
  var inner: QuadArrayInner = .init(numbers: [])
}

@StreamParseable
struct LargeUser: Equatable {
  var id: Int = 0
  var name: String = ""
}

@StreamParseable
struct LargeMeta: Equatable {
  var count: Int = 0
}

@StreamParseable
struct LargePayload: Equatable {
  var users: [LargeUser] = []
  var meta: LargeMeta = .init()
}

@StreamParseable
struct EventPayload: Equatable {
  var values: [Int] = []
}

@StreamParseable
struct Event: Equatable {
  var type: String = ""
  var payload: EventPayload = .init()
}

extension TwoKeyObject.Partial: Equatable {}
extension TrackedOnly.Partial: Equatable {}
extension NestedValue.Partial: Equatable {}
extension NestedContainer.Partial: Equatable {}
extension InitialParseableNestedValue.Partial: Equatable {}
extension InitialParseableNestedContainer.Partial: Equatable {}
extension DoubleNestedLevel2.Partial: Equatable {}
extension DoubleNestedLevel1.Partial: Equatable {}
extension DoubleNestedRoot.Partial: Equatable {}
extension NullableObject.Partial: Equatable {}
extension NullableNestedValue.Partial: Equatable {}
extension NullableNestedContainer.Partial: Equatable {}
extension EmptyObject.Partial: Equatable {}
extension IntValueContainer.Partial: Equatable {}
extension StringValueContainer.Partial: Equatable {}
extension DictionaryPropertyContainer.Partial: Equatable {}
extension ArrayPropertyContainer.Partial: Equatable {}
extension ArrayNestedLevel2.Partial: Equatable {}
extension ArrayNestedLevel1.Partial: Equatable {}
extension ArrayNestedRoot.Partial: Equatable {}
extension CombinationItem.Partial: Equatable {}
extension CombinationContainer.Partial: Equatable {}
extension CombinationMatrixItem.Partial: Equatable {}
extension CombinationMatrixContainer.Partial: Equatable {}
extension QuadArrayInner.Partial: Equatable {}
extension QuadArrayOuter.Partial: Equatable {}


@Suite
struct `JSONDump tests` {
  private let url64Kb = Bundle.module.url(forResource: "64KB", withExtension: "json")!
  private let url512Kb = Bundle.module.url(forResource: "512KB", withExtension: "json")!
  private let urlDeepNested64 = Bundle.module.url(
    forResource: "DeepNested64",
    withExtension: "json"
  )!

  @Test
  func `Small JSON Dump Optional`() throws {
    try self.assertSnapshot(of: StreamArray<ProfileOptional.Partial>.self, from: self.url64Kb)
  }

  @Test
  func `Small JSON Dump Parseable`() throws {
    try self.assertSnapshot(of: StreamArray<ProfileParseable.Partial>.self, from: self.url64Kb)
  }

  @Test
  func `Large JSON Dump Optional`() throws {
    try self.assertSnapshot(of: StreamArray<ProfileOptional.Partial>.self, from: self.url512Kb)
  }

  @Test
  func `Large JSON Dump Parseable`() throws {
    try self.assertSnapshot(of: StreamArray<ProfileParseable.Partial>.self, from: self.url512Kb)
  }

  @Test
  func `Large JSON Dump Parseable Chunked 4KB`() throws {
    try self.assertSnapshot(
      of: StreamArray<ProfileParseable.Partial>.self,
      from: self.url512Kb,
      chunkSize: 4 * 1024
    )
  }

  @Test
  func `Large JSON Dump Optional Chunked 4KB`() throws {
    try self.assertSnapshot(
      of: StreamArray<ProfileOptional.Partial>.self,
      from: self.url512Kb,
      chunkSize: 4 * 1024
    )
  }

  // The container bitmask caps depth at 64, and this fixture nests 66 deep, so it is rejected
  // rather than parsed. Pinned here so the cap stays a visible limit rather than a surprise, and
  // so raising it has to change this test deliberately.
  @Test
  func `Nesting Beyond The Depth Cap Is Rejected`() throws {
    let data = try Data(contentsOf: self.urlDeepNested64)
    var stream = PartialsStream(initialValue: DeepNestedRoot.Partial(), from: .json())
    let error = #expect(throws: JSONParsingError.self) {
      try stream.next(Array(data))
    }
    #expect(error?.reason == .depthExceeded)
  }

  private func assertSnapshot<Value: StreamParseableRoot & Encodable>(
    of type: Value.Type,
    from url: URL,
    chunkSize: Int? = nil,
    testName: String = #function
  ) throws {
    let data = try Data(contentsOf: url)
    var stream = PartialsStream(initialValue: type.streamInitialValue(), from: .json())
    if let chunkSize {
      let bytes = Array(data)
      var offset = bytes.startIndex
      while offset < bytes.endIndex {
        let endIndex = min(offset + chunkSize, bytes.endIndex)
        try stream.next(bytes[offset..<endIndex])
        offset = endIndex
      }
    } else {
      for byte in data {
        try stream.next(byte)
      }
    }
    let final = try stream.finish()
    SnapshotTesting.assertSnapshot(of: final, as: .json, testName: testName)
  }

}

@StreamParseable
struct ProfileOptional {
  var id: String
  var name: String
  var language: String
  var bio: String
  var version: Double
}

extension ProfileOptional.Partial: Codable {}

@StreamParseable(partialMembers: .streamInitialValue)
struct ProfileParseable {
  var id: String
  var name: String
  var language: String
  var bio: String
  var version: Double
}

extension ProfileParseable.Partial: Codable {}
