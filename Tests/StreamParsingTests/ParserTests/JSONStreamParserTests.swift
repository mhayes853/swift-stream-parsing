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
  }

  @Suite
  struct `JSONNumber tests` {
    @Test
    func `Streams JSON Integer Digits`() throws {
      let json = "1234"
      let expected = [1, 12, 123, 1234, 1234]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
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
      let expected = [0, -1, -12, -123, -123]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Double Zero With Trailing Decimal`() throws {
      let json = "0.0"
      let expected: [Double] = [0, 0, 0, 0]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Float Zero With Trailing Decimal`() throws {
      let json = "0.0"
      let expected: [Float] = [0, 0, 0, 0]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Double Digits`() throws {
      let json = "12.34"
      let expected: [Double] = [1, 12, 12, 12.3, 12.34, 12.34]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Negative Double Digits`() throws {
      let json = "-12.34"
      let expected: [Double] = [0, -1, -12, -12, -12.3, -12.34, -12.34]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Float Digits`() throws {
      let json = "12.34"
      let expected: [Float] = [1, 12, 12, 12.3, 12.34, 12.34]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Double Exponent Digits`() throws {
      let json = "12e3"
      let expected: [Double] = [1, 12, 12, 12, 12_000]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Double Negative Exponent Digits`() throws {
      let json = "12e-3"
      let expected: [Double] = [1, 12, 12, 12, 12, 0.012]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Double Positive Exponent Digits`() throws {
      let json = "12e+3"
      let expected: [Double] = [1, 12, 12, 12, 12, 12_000]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Double Uppercase Exponent Digits`() throws {
      let json = "12E3"
      let expected: [Double] = [1, 12, 12, 12, 12_000]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
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
      let expected: [Double] = [1, 12, 12, 12, 12, 12]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Double Negative Zero Exponent Digits`() throws {
      let json = "12e-0"
      let expected: [Double] = [1, 12, 12, 12, 12, 12]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Float Exponent Digits`() throws {
      let json = "12e3"
      let expected: [Float] = [1, 12, 12, 12, 12_000]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Float Positive Exponent Digits`() throws {
      let json = "12e+3"
      let expected: [Float] = [1, 12, 12, 12, 12, 12_000]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Float Uppercase Exponent Digits`() throws {
      let json = "12E3"
      let expected: [Float] = [1, 12, 12, 12, 12_000]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Double With Trailing Decimal Zero`() throws {
      let json = "11.0"
      let expected: [Double] = [1, 11, 11, 11, 11]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Float With Trailing Decimal Zero`() throws {
      let json = "11.0"
      let expected: [Float] = [1, 11, 11, 11, 11]
      try expectJSONStreamedValues(json, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams JSON Large Integer Digits`() throws {
      let json = "18446744073709551615"
      let expected: [UInt64] = [
        1,
        18,
        184,
        1_844,
        18_446,
        184_467,
        1_844_674,
        18_446_744,
        184_467_440,
        1_844_674_407,
        18_446_744_073,
        184_467_440_737,
        1_844_674_407_370,
        18_446_744_073_709,
        184_467_440_737_095,
        1_844_674_407_370_955,
        18_446_744_073_709_551,
        184_467_440_737_095_516,
        1_844_674_407_370_955_161,
        18_446_744_073_709_551_615,
        18_446_744_073_709_551_615
      ]
      try expectJSONStreamedValues(json, initialValue: UInt64(0), expected: expected)
    }

    @Test
    func `Streams JSON Large Negative Integer Digits`() throws {
      let json = "-9223372036854775807"
      let expected: [Int64] = [
        0,
        -9,
        -92,
        -922,
        -9_223,
        -92_233,
        -922_337,
        -9_223_372,
        -92_233_720,
        -922_337_203,
        -9_223_372_036,
        -92_233_720_368,
        -922_337_203_685,
        -9_223_372_036_854,
        -92_233_720_368_547,
        -922_337_203_685_477,
        -9_223_372_036_854_775,
        -92_233_720_368_547_758,
        -922_337_203_685_477_580,
        -9_223_372_036_854_775_807,
        -9_223_372_036_854_775_807
      ]
      try expectJSONStreamedValues(json, initialValue: Int64(0), expected: expected)
    }

    @Test
    @available(StreamParsing128BitIntegers, *)
    func `Streams JSON Large UInt128 Digits`() throws {
      let json = "340282366920938463463374607431768211455"
      let expected: [UInt128] = [
        3,
        34,
        340,
        3_402,
        34_028,
        340_282,
        3_402_823,
        34_028_236,
        340_282_366,
        3_402_823_669,
        34_028_236_692,
        340_282_366_920,
        3_402_823_669_209,
        34_028_236_692_093,
        340_282_366_920_938,
        3_402_823_669_209_384,
        34_028_236_692_093_846,
        340_282_366_920_938_463,
        3_402_823_669_209_384_634,
        34_028_236_692_093_846_346,
        340_282_366_920_938_463_463,
        3_402_823_669_209_384_634_633,
        34_028_236_692_093_846_346_337,
        340_282_366_920_938_463_463_374,
        3_402_823_669_209_384_634_633_746,
        34_028_236_692_093_846_346_337_460,
        340_282_366_920_938_463_463_374_607,
        3_402_823_669_209_384_634_633_746_074,
        34_028_236_692_093_846_346_337_460_743,
        340_282_366_920_938_463_463_374_607_431,
        3_402_823_669_209_384_634_633_746_074_317,
        34_028_236_692_093_846_346_337_460_743_176,
        340_282_366_920_938_463_463_374_607_431_768,
        3_402_823_669_209_384_634_633_746_074_317_682,
        34_028_236_692_093_846_346_337_460_743_176_821,
        340_282_366_920_938_463_463_374_607_431_768_211,
        3_402_823_669_209_384_634_633_746_074_317_682_114,
        34_028_236_692_093_846_346_337_460_743_176_821_145,
        340_282_366_920_938_463_463_374_607_431_768_211_455,
        340_282_366_920_938_463_463_374_607_431_768_211_455
      ]
      try expectJSONStreamedValues(json, initialValue: UInt128(0), expected: expected)
    }

    @Test
    @available(StreamParsing128BitIntegers, *)
    func `Streams JSON Large Negative Int128 Digits`() throws {
      let json = "-170141183460469231731687303715884105727"
      let expected: [Int128] = [
        0,
        -1,
        -17,
        -170,
        -1_701,
        -17_014,
        -170_141,
        -1_701_411,
        -17_014_118,
        -170_141_183,
        -1_701_411_834,
        -17_014_118_346,
        -170_141_183_460,
        -1_701_411_834_604,
        -17_014_118_346_046,
        -170_141_183_460_469,
        -1_701_411_834_604_692,
        -17_014_118_346_046_923,
        -170_141_183_460_469_231,
        -1_701_411_834_604_692_317,
        -17_014_118_346_046_923_173,
        -170_141_183_460_469_231_731,
        -1_701_411_834_604_692_317_316,
        -17_014_118_346_046_923_173_168,
        -170_141_183_460_469_231_731_687,
        -1_701_411_834_604_692_317_316_873,
        -17_014_118_346_046_923_173_168_730,
        -170_141_183_460_469_231_731_687_303,
        -1_701_411_834_604_692_317_316_873_037,
        -17_014_118_346_046_923_173_168_730_371,
        -170_141_183_460_469_231_731_687_303_715,
        -1_701_411_834_604_692_317_316_873_037_158,
        -17_014_118_346_046_923_173_168_730_371_588,
        -170_141_183_460_469_231_731_687_303_715_884,
        -1_701_411_834_604_692_317_316_873_037_158_841,
        -17_014_118_346_046_923_173_168_730_371_588_410,
        -170_141_183_460_469_231_731_687_303_715_884_105,
        -1_701_411_834_604_692_317_316_873_037_158_841_057,
        -17_014_118_346_046_923_173_168_730_371_588_410_572,
        -170_141_183_460_469_231_731_687_303_715_884_105_727,
        -170_141_183_460_469_231_731_687_303_715_884_105_727
      ]
      try expectJSONStreamedValues(json, initialValue: Int128(0), expected: expected)
    }
  }

  @Suite
  struct `JSONArray tests` {
    @Test
    func `Streams JSON Integer Array`() throws {
      let json = "[1,2]"
      let expected: [[Int]] = [
        [],
        [1],
        [1],
        [1, 2],
        [1, 2],
        [1, 2]
      ]
      try expectJSONStreamedValues(json, initialValue: [Int](), expected: expected)
    }

    @Test
    func `Streams JSON Integer Array With Heavy Whitespace`() throws {
      let json = "[  1    ,    2   ]"
      let expected: [[Int]] = [
        [],
        [],
        [],
        [1],
        [1],
        [1],
        [1],
        [1],
        [1],
        [1],
        [1],
        [1],
        [1],
        [1, 2],
        [1, 2],
        [1, 2],
        [1, 2],
        [1, 2],
        [1, 2]
      ]
      try expectJSONStreamedValues(json, initialValue: [Int](), expected: expected)
    }

    @Test
    func `Streams JSON Array With Fractional And Exponential Double`() throws {
      let json = "[12.34,12e3]"
      let expected: [[Double]] = [
        [],
        [1],
        [12],
        [12],
        [12.3],
        [12.34],
        [12.34],
        [12.34, 1],
        [12.34, 12],
        [12.34, 12],
        [12.34, 12],
        [12.34, 12_000],
        [12.34, 12_000]
      ]
      try expectJSONStreamedValues(json, initialValue: [Double](), expected: expected)
    }

    @Test
    func `Streams JSON Integer 2D Array`() throws {
      let json = "[[1],[2]]"
      let expected: [[[Int]]] = [
        [],
        [[]],
        [[1]],
        [[1]],
        [[1]],
        [[1], []],
        [[1], [2]],
        [[1], [2]],
        [[1], [2]],
        [[1], [2]]
      ]
      try expectJSONStreamedValues(json, initialValue: [[Int]](), expected: expected)
    }

    @Test
    func `Streams JSON String Array`() throws {
      let json = "[\"a\",\"b\"]"
      let expected: [[String]] = [
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
      try expectJSONStreamedValues(json, initialValue: [String](), expected: expected)
    }

    @Test
    func `Streams JSON String 2D Array`() throws {
      let json = "[[\"a\"],[\"b\"]]"
      let expected: [[[String]]] = [
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
      try expectJSONStreamedValues(json, initialValue: [[String]](), expected: expected)
    }

    @Test
    func `Streams JSON Boolean Array`() throws {
      let json = "[true,false]"
      let expected: [[Bool]] = [
        [],
        [true],
        [true],
        [true],
        [true],
        [true],
        [true, false],
        [true, false],
        [true, false],
        [true, false],
        [true, false],
        [true, false],
        [true, false]
      ]
      try expectJSONStreamedValues(json, initialValue: [Bool](), expected: expected)
    }

    @Test
    func `Streams JSON Boolean 2D Array`() throws {
      let json = "[[true],[false]]"
      let expected: [[[Bool]]] = [
        [],
        [[]],
        [[true]],
        [[true]],
        [[true]],
        [[true]],
        [[true]],
        [[true]],
        [[true], []],
        [[true], [false]],
        [[true], [false]],
        [[true], [false]],
        [[true], [false]],
        [[true], [false]],
        [[true], [false]],
        [[true], [false]],
        [[true], [false]]
      ]
      try expectJSONStreamedValues(json, initialValue: [[Bool]](), expected: expected)
    }

    @Test
    func `Streams JSON Optional Array`() throws {
      let json = "[1,null]"
      let expected: [[Int?]] = [
        [],
        [1],
        [1],
        [1, nil],
        [1, nil],
        [1, nil],
        [1, nil],
        [1, nil],
        [1, nil]
      ]
      try expectJSONStreamedValues(json, initialValue: [Int?](), expected: expected)
    }

    @Test
    func `Streams JSON Optional 2D Array`() throws {
      let json = "[[null],[1]]"
      let expected: [[[Int?]]] = [
        [],
        [[]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil], []],
        [[nil], [1]],
        [[nil], [1]],
        [[nil], [1]],
        [[nil], [1]]
      ]
      try expectJSONStreamedValues(json, initialValue: [[Int?]](), expected: expected)
    }

    @Test
    func `Streams JSON Integer 3D Array Single Element`() throws {
      let json = "[[[1]]]"
      let expected: [[[[Int]]]] = [
        [],
        [[]],
        [[[]]],
        [[[1]]],
        [[[1]]],
        [[[1]]],
        [[[1]]],
        [[[1]]]
      ]
      try expectJSONStreamedValues(json, initialValue: [[[Int]]](), expected: expected)
    }
  }

  @Suite
  struct `JSONObject tests` {
    @Test
    func `Streams JSON Empty Object Into Dictionary`() throws {
      let json = "{}"
      let expected: [[String: Int]] = [[:], [:], [:]]
      try expectJSONStreamedValues(json, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams JSON Object With Single Key Into Dictionary`() throws {
      let json = "{\"single\":1}"
      let initial = Array(repeating: [String: Int](), count: 10)
      let updated = Array(repeating: ["single": 1], count: 3)
      let expected: [[String: Int]] = initial + updated
      try expectJSONStreamedValues(json, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams JSON Object With Two Keys Into Dictionary`() throws {
      let json = "{\"first\":1,\"second\":2}"
      let initial = Array(repeating: [String: Int](), count: 9)
      let firstPhase = Array(repeating: ["first": 1], count: 11)
      let finalPhase = Array(repeating: ["first": 1, "second": 2], count: 3)
      let expected: [[String: Int]] = initial + firstPhase + finalPhase
      try expectJSONStreamedValues(json, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams JSON Object With Two Keys Into StreamParseable Struct`() throws {
      let json = "{\"first\":1,\"second\":2}"
      let initial = Array(repeating: TwoKeyObject.Partial(), count: 9)
      let firstPhase = Array(repeating: TwoKeyObject.Partial(first: 1), count: 11)
      let finalPhase = Array(repeating: TwoKeyObject.Partial(first: 1, second: 2), count: 3)
      let expected = initial + firstPhase + finalPhase
      try expectJSONStreamedValues(json, initialValue: TwoKeyObject.Partial(), expected: expected)
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
      let initial = Array(repeating: [String: Int](), count: 13)
      let firstPhase = Array(repeating: ["first": 1], count: 15)
      let finalPhase = Array(repeating: ["first": 1, "second": 2], count: 4)
      let expected: [[String: Int]] = initial + firstPhase + finalPhase
      try expectJSONStreamedValues(json, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams Nested JSON Object Into Dictionary Of Dictionaries`() throws {
      let json = "{\"outer\":{\"inner\":1}}"
      let initial = Array(repeating: [String: [String: Int]](), count: 9)
      let nestedEmpty = Array(
        repeating: ["outer": [String: Int]()],
        count: 9
      )
      let populated = Array(
        repeating: ["outer": ["inner": 1]],
        count: 4
      )
      let expected: [[String: [String: Int]]] = initial + nestedEmpty + populated
      try expectJSONStreamedValues(
        json,
        initialValue: [String: [String: Int]](),
        expected: expected
      )
    }

    @Test
    func `Streams Nested JSON Object Into StreamParseable Struct`() throws {
      let json = "{\"nested\":{\"value\":1}}"
      let initial = Array(repeating: NestedContainer.Partial(), count: 19)
      let populated = Array(
        repeating: NestedContainer.Partial(
          nested: NestedValue.Partial(value: 1)
        ),
        count: 4
      )
      let expected = initial + populated
      try expectJSONStreamedValues(
        json,
        initialValue: NestedContainer.Partial(),
        expected: expected
      )
    }

    @Test
    func
      `Streams Nested JSON Object Into StreamParseable Struct With Initial Parseable Partial Members`()
      throws
    {
      let json = "{\"nested\":{\"value\":1}}"
      let initial = Array(repeating: InitialParseableNestedContainer.Partial(), count: 19)
      let populated = Array(
        repeating: InitialParseableNestedContainer.Partial(
          nested: InitialParseableNestedValue.Partial(value: 1)
        ),
        count: 4
      )
      let expected = initial + populated
      try expectJSONStreamedValues(
        json,
        initialValue: InitialParseableNestedContainer.Partial(),
        expected: expected
      )
    }

    @Test
    func `Streams Doubly Nested JSON Object Into Dictionary Of Dictionaries Of Dictionaries`()
      throws
    {
      let json = "{\"level1\":{\"level2\":{\"value\":1}}}"
      let initial = Array(
        repeating: [String: [String: [String: Int]]](),
        count: 10
      )
      let firstNested = Array(
        repeating: ["level1": [String: [String: Int]]()],
        count: 10
      )
      let secondNested = Array(
        repeating: ["level1": ["level2": [String: Int]()]],
        count: 9
      )
      let populated = Array(
        repeating: ["level1": ["level2": ["value": 1]]],
        count: 5
      )
      let expected = initial + firstNested + secondNested + populated
      try expectJSONStreamedValues(
        json,
        initialValue: [String: [String: [String: Int]]](),
        expected: expected
      )
    }

    @Test
    func `Streams Doubly Nested JSON Object Into StreamParseable Struct`() throws {
      let json = "{\"level1\":{\"level2\":{\"value\":1}}}"
      let initial = Array(repeating: DoubleNestedRoot.Partial(), count: 29)
      let populated = Array(
        repeating: DoubleNestedRoot.Partial(
          level1: DoubleNestedLevel1.Partial(
            level2: DoubleNestedLevel2.Partial(value: 1)
          )
        ),
        count: 5
      )
      let expected = initial + populated
      try expectJSONStreamedValues(
        json,
        initialValue: DoubleNestedRoot.Partial(),
        expected: expected
      )
    }

    @Test
    func `Streams JSON Object With Fractional And Exponential Doubles Into Dictionary`() throws {
      let json = "{\"fractional\":12.34,\"exponential\":12e3}"
      let stageOne = Array(repeating: [String: Double](), count: 14)
      let fractionalProgress: [[String: Double]] = [
        ["fractional": 1],
        ["fractional": 12],
        ["fractional": 12],
        ["fractional": 12.3],
        ["fractional": 12.34]
      ]
      let fractionalHolding = Array(repeating: ["fractional": 12.34], count: 15)
      let exponentialPhase: [[String: Double]] = [
        ["fractional": 12.34, "exponential": 1],
        ["fractional": 12.34, "exponential": 12],
        ["fractional": 12.34, "exponential": 12],
        ["fractional": 12.34, "exponential": 12],
        ["fractional": 12.34, "exponential": 12_000],
        ["fractional": 12.34, "exponential": 12_000]
      ]
      let expected = stageOne + fractionalProgress + fractionalHolding + exponentialPhase
      try expectJSONStreamedValues(json, initialValue: [String: Double](), expected: expected)
    }

    @Test
    func `Streams JSON Object With Nullable Value Into StreamParseable Struct`() throws {
      let json = "{\"maybe\":null}"
      let beforeNull = Array(repeating: NullableObject.Partial(), count: 9)
      let afterNull = Array(
        repeating: NullableObject.Partial(maybe: .some(nil)),
        count: 6
      )
      let expected = beforeNull + afterNull
      try expectJSONStreamedValues(json, initialValue: NullableObject.Partial(), expected: expected)
    }

    @Test
    func `Streams JSON Object With Nested Nullable Value Into StreamParseable Struct`() throws {
      let json = "{\"inner\":{\"maybe\":null}}"
      let beforeNull = Array(repeating: NullableNestedContainer.Partial(), count: 18)
      let afterNull = Array(
        repeating: NullableNestedContainer.Partial(
          inner: NullableNestedValue.Partial(maybe: .some(nil))
        ),
        count: 7
      )
      let expected = beforeNull + afterNull
      try expectJSONStreamedValues(
        json,
        initialValue: NullableNestedContainer.Partial(),
        expected: expected
      )
    }

    @Test
    func `Streams JSON Object With Nullable Value Into Dictionary`() throws {
      let json = "{\"maybe\":null}"
      let beforeNull = Array(repeating: [String: Int?](), count: 9)
      let afterNull = Array(
        repeating: ["maybe": nil] as [String: Int?],
        count: 6
      )
      let expected = beforeNull + afterNull
      try expectJSONStreamedValues(json, initialValue: [String: Int?](), expected: expected)
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
      let beforeInner = Array(repeating: DictionaryPropertyContainer.Partial(), count: 10)
      let beforeElement = Array(
        repeating: DictionaryPropertyContainer.Partial(values: [:]),
        count: 9
      )
      let populated = Array(
        repeating: DictionaryPropertyContainer.Partial(values: ["inner": 1]),
        count: 4
      )
      let expected = beforeInner + beforeElement + populated
      try expectJSONStreamedValues(
        json,
        initialValue: DictionaryPropertyContainer.Partial(),
        expected: expected
      )
    }

    @Test
    func `Streams JSON Object With Array Property Into StreamParseable Struct`() throws {
      let json = "{\"numbers\":[1,2]}"
      let beforeArray = Array(repeating: ArrayPropertyContainer.Partial(), count: 11)
      let arrayProgress: [ArrayPropertyContainer.Partial] = [
        ArrayPropertyContainer.Partial(numbers: []),
        ArrayPropertyContainer.Partial(numbers: [1]),
        ArrayPropertyContainer.Partial(numbers: [1]),
        ArrayPropertyContainer.Partial(numbers: [1, 2]),
        ArrayPropertyContainer.Partial(numbers: [1, 2]),
        ArrayPropertyContainer.Partial(numbers: [1, 2]),
        ArrayPropertyContainer.Partial(numbers: [1, 2])
      ]
      let expected = beforeArray + arrayProgress
      try expectJSONStreamedValues(
        json,
        initialValue: ArrayPropertyContainer.Partial(),
        expected: expected
      )
    }

    @Test
    func `Streams JSON Object With Nested Array Property Into StreamParseable Struct`() throws {
      let json = "{\"level1\":{\"level2\":{\"numbers\":[1,2]}}}"
      let beforeArray = Array(repeating: ArrayNestedRoot.Partial(), count: 31)
      let arrayProgress: [ArrayNestedRoot.Partial] = [
        ArrayNestedRoot.Partial(
          level1: ArrayNestedLevel1.Partial(
            level2: ArrayNestedLevel2.Partial(numbers: [])
          )
        ),
        ArrayNestedRoot.Partial(
          level1: ArrayNestedLevel1.Partial(
            level2: ArrayNestedLevel2.Partial(numbers: [1])
          )
        ),
        ArrayNestedRoot.Partial(
          level1: ArrayNestedLevel1.Partial(
            level2: ArrayNestedLevel2.Partial(numbers: [1])
          )
        ),
        ArrayNestedRoot.Partial(
          level1: ArrayNestedLevel1.Partial(
            level2: ArrayNestedLevel2.Partial(numbers: [1, 2])
          )
        ),
        ArrayNestedRoot.Partial(
          level1: ArrayNestedLevel1.Partial(
            level2: ArrayNestedLevel2.Partial(numbers: [1, 2])
          )
        ),
        ArrayNestedRoot.Partial(
          level1: ArrayNestedLevel1.Partial(
            level2: ArrayNestedLevel2.Partial(numbers: [1, 2])
          )
        ),
        ArrayNestedRoot.Partial(
          level1: ArrayNestedLevel1.Partial(
            level2: ArrayNestedLevel2.Partial(numbers: [1, 2])
          )
        ),
        ArrayNestedRoot.Partial(
          level1: ArrayNestedLevel1.Partial(
            level2: ArrayNestedLevel2.Partial(numbers: [1, 2])
          )
        ),
        ArrayNestedRoot.Partial(
          level1: ArrayNestedLevel1.Partial(
            level2: ArrayNestedLevel2.Partial(numbers: [1, 2])
          )
        )
      ]
      let expected = beforeArray + arrayProgress
      try expectJSONStreamedValues(
        json,
        initialValue: ArrayNestedRoot.Partial(),
        expected: expected
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
        _ = try stream.next(byte)
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
      let initial = Array(repeating: [String: Int](), count: 9)
      let firstValue = Array(repeating: ["value": 1], count: 10)
      let overwrittenValue = Array(repeating: ["value": 2], count: 3)
      let expected: [[String: Int]] = initial + firstValue + overwrittenValue
      try expectJSONStreamedValues(json, initialValue: [String: Int](), expected: expected)
    }
  }

  @Suite
  struct `JSONCombination tests` {
    @Test
    func `Streams JSON Array Of StreamParseable Structs`() throws {
      let json = "[{\"value\":1}]"
      let initial = Array(repeating: [CombinationItem.Partial](), count: 1)
      let objectStart = Array(repeating: [CombinationItem.Partial()], count: 9)
      let populated = Array(
        repeating: [CombinationItem.Partial(value: 1)],
        count: 4
      )
      let expected = initial + objectStart + populated
      try expectJSONStreamedValues(
        json,
        initialValue: [CombinationItem.Partial](),
        expected: expected
      )
    }

    @Test
    func `Streams JSON Array Of StreamParseable Structs With Multiple Elements`() throws {
      let json = "[{\"value\":1},{\"value\":2}]"
      let initial = Array(repeating: [CombinationItem.Partial](), count: 1)
      let firstObject = Array(
        repeating: [CombinationItem.Partial()],
        count: 9
      )
      let firstValue = Array(
        repeating: [CombinationItem.Partial(value: 1)],
        count: 3
      )
      let secondObject = Array(
        repeating: [CombinationItem.Partial(value: 1), CombinationItem.Partial()],
        count: 9
      )
      let finalValues = Array(
        repeating: [CombinationItem.Partial(value: 1), CombinationItem.Partial(value: 2)],
        count: 4
      )
      let expected = initial + firstObject + firstValue + secondObject + finalValues
      try expectJSONStreamedValues(
        json,
        initialValue: [CombinationItem.Partial](),
        expected: expected
      )
    }

    @Test
    func `Streams JSON Empty Array Of StreamParseable Structs`() throws {
      let json = "[]"
      let expected = Array(repeating: [CombinationItem.Partial](), count: 3)
      try expectJSONStreamedValues(
        json,
        initialValue: [CombinationItem.Partial](),
        expected: expected
      )
    }

    @Test
    func `Streams JSON Object With Array Of StreamParseable Structs`() throws {
      let json = "{\"items\":[{\"value\":1}]}"
      let beforeArray = Array(repeating: CombinationContainer.Partial(), count: 9)
      let arrayStart = Array(repeating: CombinationContainer.Partial(items: []), count: 1)
      let itemStarted = Array(
        repeating: CombinationContainer.Partial(items: [CombinationItem.Partial()]),
        count: 9
      )
      let itemPopulated = Array(
        repeating: CombinationContainer.Partial(items: [CombinationItem.Partial(value: 1)]),
        count: 5
      )
      let expected = beforeArray + arrayStart + itemStarted + itemPopulated
      try expectJSONStreamedValues(
        json,
        initialValue: CombinationContainer.Partial(),
        expected: expected
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
      let beforeArray = Array(repeating: CombinationContainer.Partial(), count: 9)
      let arrayStart = Array(repeating: CombinationContainer.Partial(items: []), count: 1)
      let firstItemStarted = Array(
        repeating: CombinationContainer.Partial(items: [CombinationItem.Partial()]),
        count: 9
      )
      let firstItemPopulated = Array(
        repeating: CombinationContainer.Partial(items: [CombinationItem.Partial(value: 1)]),
        count: 3
      )
      let secondItemStarted = Array(
        repeating: CombinationContainer.Partial(
          items: [CombinationItem.Partial(value: 1), CombinationItem.Partial()]
        ),
        count: 9
      )
      let secondItemPopulated = Array(
        repeating: CombinationContainer.Partial(
          items: [CombinationItem.Partial(value: 1), CombinationItem.Partial(value: 2)]
        ),
        count: 5
      )
      let expected =
        beforeArray + arrayStart + firstItemStarted + firstItemPopulated + secondItemStarted
        + secondItemPopulated
      try expectJSONStreamedValues(
        json,
        initialValue: CombinationContainer.Partial(),
        expected: expected
      )
    }

    @Test
    func `Streams Quadruple Nested JSON Object Array Array Object`() throws {
      let json = "{\"matrix\":[[{\"value\":1}]]}"
      let beforeArray = Array(repeating: CombinationMatrixContainer.Partial(), count: 10)
      let outerArrayStart = Array(
        repeating: CombinationMatrixContainer.Partial(matrix: []),
        count: 1
      )
      let innerArrayStart = Array(
        repeating: CombinationMatrixContainer.Partial(matrix: [[]]),
        count: 1
      )
      let objectStarted = Array(
        repeating: CombinationMatrixContainer.Partial(
          matrix: [[CombinationMatrixItem.Partial()]]
        ),
        count: 9
      )
      let populated = Array(
        repeating: CombinationMatrixContainer.Partial(
          matrix: [[CombinationMatrixItem.Partial(value: 1)]]
        ),
        count: 6
      )
      let expected = beforeArray + outerArrayStart + innerArrayStart + objectStarted + populated
      try expectJSONStreamedValues(
        json,
        initialValue: CombinationMatrixContainer.Partial(),
        expected: expected
      )
    }

    @Test
    func `Streams Quadruple Nested JSON Array Object Object Array`() throws {
      let json = "[{\"inner\":{\"numbers\":[1,2]}}]"
      let arrayStart = Array(repeating: [QuadArrayOuter.Partial](), count: 1)
      let beforeNumbers = Array(repeating: [QuadArrayOuter.Partial()], count: 20)
      let numbersStart = Array(
        repeating: [QuadArrayOuter.Partial(inner: QuadArrayInner.Partial(numbers: []))],
        count: 1
      )
      let firstNumber = Array(
        repeating: [QuadArrayOuter.Partial(inner: QuadArrayInner.Partial(numbers: [1]))],
        count: 1
      )
      let comma = Array(
        repeating: [QuadArrayOuter.Partial(inner: QuadArrayInner.Partial(numbers: [1]))],
        count: 1
      )
      let secondNumber = Array(
        repeating: [QuadArrayOuter.Partial(inner: QuadArrayInner.Partial(numbers: [1, 2]))],
        count: 1
      )
      let closing = Array(
        repeating: [QuadArrayOuter.Partial(inner: QuadArrayInner.Partial(numbers: [1, 2]))],
        count: 5
      )
      let expected =
        arrayStart + beforeNumbers + numbersStart + firstNumber + comma + secondNumber + closing
      try expectJSONStreamedValues(
        json,
        initialValue: [QuadArrayOuter.Partial](),
        expected: expected
      )
    }
  }

  @Suite
  struct `JSONError tests` {
    @Test
    func `Streams Values Before Syntax Error`() {
      let json = "[1,2,x]"
      let expected: [[Int]] = [
        [],
        [1],
        [1],
        [1, 2],
        [1, 2]
      ]
      expectJSONStreamedValuesBeforeError(
        json,
        initialValue: [Int](),
        expected: expected,
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Missing Value`() {
      let json = "{\"a\":}"
      expectJSONStreamParsingError(
        json,
        initialValue: [String: Int](),
        reason: .missingValue
      )
    }

    @Test
    func `Throws For Missing Colon`() {
      let json = "{\"a\" 1}"
      expectJSONStreamParsingError(
        json,
        initialValue: [String: Int](),
        reason: .missingColon
      )
    }

    @Test
    func `Throws For Trailing Comma In Object`() {
      let json = "{\"a\": 1,}"
      expectJSONStreamParsingError(
        json,
        initialValue: [String: Int](),
        reason: .trailingComma
      )
    }

    @Test
    func `Throws For Trailing Comma In Array`() {
      let json = "[1,]"
      expectJSONStreamParsingError(
        json,
        initialValue: [Int](),
        reason: .trailingComma
      )
    }

    @Test
    func `Throws For Missing Comma In Array`() {
      let json = "[1 2]"
      expectJSONStreamParsingError(
        json,
        initialValue: [Int](),
        reason: .missingComma
      )
    }

    @Test
    func `Throws For Unterminated String`() {
      let json = "\"unterminated"
      expectJSONStreamParsingError(
        json,
        initialValue: "",
        reason: .unterminatedString
      )
    }

    @Test
    func `Throws For Invalid Unicode Escape`() {
      let json = "\"\\u12\""
      expectJSONStreamParsingError(
        json,
        initialValue: "",
        reason: .invalidUnicodeEscape
      )
    }

    @Test
    func `Throws For Missing Closing Brace`() {
      let json = "{\"a\": 1"
      expectJSONStreamParsingError(
        json,
        initialValue: [String: Int](),
        reason: .missingClosingBrace
      )
    }

    @Test
    func `Throws For Missing Closing Bracket`() {
      let json = "[1,2"
      expectJSONStreamParsingError(
        json,
        initialValue: [Int](),
        reason: .missingClosingBracket
      )
    }

    @Test
    func `Throws For Unexpected Token In Neutral Mode`() {
      let json = "]["
      expectJSONStreamParsingError(
        json,
        initialValue: [Int](),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Invalid Literal`() {
      let json = "{\"a\": tru}"
      expectJSONStreamParsingError(
        json,
        initialValue: [String: Bool](),
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Invalid Number`() {
      let json = "{\"a\": -}"
      expectJSONStreamParsingError(
        json,
        initialValue: [String: Int](),
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Integer Overflow`() {
      let json = "[18446744073709551616]"
      expectJSONStreamParsingError(
        json,
        initialValue: [UInt64](),
        reason: .numericOverflow
      )
    }

    @Test
    func `Throws For Int32 Overflow`() {
      let json = "2147483648"
      expectJSONStreamParsingError(
        json,
        initialValue: Int32(),
        reason: .numericOverflow
      )
    }

    @Test
    func `Throws For UInt32 Overflow`() {
      let json = "4294967296"
      expectJSONStreamParsingError(
        json,
        initialValue: UInt32(),
        reason: .numericOverflow
      )
    }

    @Test
    func `Throws For Int8 Overflow`() {
      let json = "-129"
      expectJSONStreamParsingError(
        json,
        initialValue: Int8(),
        reason: .numericOverflow
      )
    }

    @Test
    func `Throws For Float Overflow`() {
      let json = "3.5e38"
      expectJSONStreamParsingError(
        json,
        initialValue: Float(),
        reason: .numericOverflow
      )
    }

    @Test
    func `Throws For Double Overflow`() {
      let json = "1e400"
      expectJSONStreamParsingError(
        json,
        initialValue: Double(),
        reason: .numericOverflow
      )
    }

    @Test
    func `Throws For Leading Zero`() {
      let json = "{\"a\": 01}"
      expectJSONStreamParsingError(
        json,
        initialValue: [String: Int](),
        reason: .leadingZero
      )
    }

    @Test
    func `Throws For Invalid Hex Number When Enabled`() {
      let json = "0x"
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.hexNumbers]),
        initialValue: 0,
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Invalid Hex Number Without Prefix When Enabled`() {
      let json = "1x34"
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.hexNumbers]),
        initialValue: 0,
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Invalid Hex Number With Extra Leading Zero When Enabled`() {
      let json = "00x78"
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.hexNumbers]),
        initialValue: 0,
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Invalid Exponent`() {
      let json = "{\"a\": 1e}"
      expectJSONStreamParsingError(
        json,
        initialValue: [String: Double](),
        reason: .invalidExponent
      )
    }

    @Test
    func `Throws For Exponent Overflow`() {
      let json = "1e9223372036854775808"
      expectJSONStreamParsingError(
        json,
        initialValue: Double(),
        reason: .numericOverflow
      )
    }

    @Test
    func `Throws For Unterminated Single Quoted String When Enabled`() {
      let json = "'unterminated"
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.singleQuotedStrings]),
        initialValue: "",
        reason: .unterminatedString
      )
    }

    @Test
    func `Throws For Mismatched Single Quoted String When Enabled`() {
      let json = "'mismatch\""
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.singleQuotedStrings]),
        initialValue: "",
        reason: .unterminatedString
      )
    }

    @Test
    func `Throws For Unquoted Key With Whitespace When Enabled`() {
      let json = "{bad key: 1}"
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.unquotedKeys]),
        initialValue: [String: Int](),
        reason: .missingColon
      )
    }

    @Test
    func `Throws For Unquoted Key With Punctuation When Enabled`() {
      let json = "{bad-key: 1}"
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.unquotedKeys]),
        initialValue: [String: Int](),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Unterminated Single Quoted Key When Enabled`() {
      let json = "{'key: 1}"
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.singleQuotedStrings]),
        initialValue: [String: Int](),
        reason: .unterminatedString
      )
    }

    @Test
    func `Throws For Mismatched Single Quoted Key When Enabled`() {
      let json = "{'key\": 1}"
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.singleQuotedStrings]),
        initialValue: [String: Int](),
        reason: .unterminatedString
      )
    }

    @Test
    func `Throws For Unescaped Single Quote In Single Quoted String When Enabled`() {
      let json = "'bad 'quote'"
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.singleQuotedStrings]),
        initialValue: "",
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Unescaped Single Quote In Single Quoted Key When Enabled`() {
      let json = "{'bad 'key': 1}"
      expectJSONStreamParsingError(
        json,
        configuration: JSONStreamParserConfiguration(syntaxOptions: [.singleQuotedStrings]),
        initialValue: [String: Int](),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Missing Closing Brace In Larger Payload`() {
      let json =
        "{\"users\":[{\"id\":1,\"name\":\"Ada\"},{\"id\":2,\"name\":\"Grace\"}],\"meta\":{\"count\":2}"
      expectJSONStreamParsingError(
        json,
        initialValue: LargePayload.Partial(),
        reason: .missingClosingBrace
      )
    }

    @Test
    func `Throws For Trailing Comma In Larger Array Payload`() {
      let json =
        "[{\"type\":\"event\",\"payload\":{\"values\":[1,2,3]}},{\"type\":\"event\",\"payload\":{\"values\":[4,5,6]}},]"
      expectJSONStreamParsingError(
        json,
        initialValue: [Event.Partial](),
        reason: .trailingComma
      )
    }

    @Test
    func `Throws With Position For Invalid Token`() {
      let json = "{\n\"a\": 1,\n\"b\": x\n}"
      expectJSONStreamParsingError(
        json,
        initialValue: [String: Int](),
        reason: .unexpectedToken,
        position: JSONStreamParsingPosition(line: 3, column: 6)
      )
    }
  }

  @Suite
  struct `JSONBoolean tests` {
    @Test
    func `Streams JSON True`() throws {
      let json = "true"
      let expected = [true, true, true, true, true]
      try expectJSONStreamedValues(json, initialValue: false, expected: expected)
    }

    @Test
    func `Streams JSON False`() throws {
      let json = "false"
      let expected = [false, false, false, false, false, false]
      try expectJSONStreamedValues(json, initialValue: true, expected: expected)
    }
  }

  @Suite
  struct `JSONNull tests` {
    @Test
    func `Streams JSON Null`() throws {
      let json = "null"
      let expected: [String?] = [nil, nil, nil, nil, nil]
      try expectJSONStreamedValues(json, initialValue: "seed", expected: expected)
    }
  }

  @Suite
  struct `JSONConfiguration tests` {
    @Test
    func `Allows Trailing Comma In Array When Enabled`() throws {
      let json = "[1,2,]"
      let values = try json.utf8.partials(
        initialValue: [Int](),
        from: .json(configuration: JSONStreamParserConfiguration(syntaxOptions: [.trailingCommas]))
      )
      expectNoDifference(values.last, [1, 2])
    }

    @Test
    func `Allows Trailing Comma In Object When Enabled`() throws {
      let json = "{\"a\":1,}"
      let values = try json.utf8.partials(
        initialValue: [String: Int](),
        from: .json(configuration: JSONStreamParserConfiguration(syntaxOptions: [.trailingCommas]))
      )
      expectNoDifference(values.last, ["a": 1])
    }

    @Test
    func `Allows Comments When Enabled`() throws {
      let json = "/*comment*/1"
      let values = try json.utf8.partials(
        initialValue: 0,
        from: .json(configuration: JSONStreamParserConfiguration(syntaxOptions: [.comments]))
      )
      expectNoDifference(values.last, 1)
    }

    @Test
    func `Allows Single Line Comments In Multi Line Array When Enabled`() throws {
      let json = """
        [
          1,
          // comment
          2
        ]
        """
      let values = try json.utf8.partials(
        initialValue: [Int](),
        from: .json(configuration: JSONStreamParserConfiguration(syntaxOptions: [.comments]))
      )
      expectNoDifference(values.last, [1, 2])
    }

    @Test
    func `Allows Single Line Comments In Multi Line Object When Enabled`() throws {
      let json = """
        {
          "a": 1,
          // comment
          "b": 2
        }
        """
      let values = try json.utf8.partials(
        initialValue: [String: Int](),
        from: .json(configuration: JSONStreamParserConfiguration(syntaxOptions: [.comments]))
      )
      expectNoDifference(values.last, ["a": 1, "b": 2])
    }

    @Test
    func `Allows Single Quoted Strings When Enabled`() throws {
      let json = "'Blob'"
      let values = try json.utf8.partials(
        initialValue: "",
        from: .json(
          configuration: JSONStreamParserConfiguration(syntaxOptions: [.singleQuotedStrings])
        )
      )
      expectNoDifference(values.last, "Blob")
    }

    @Test
    func `Allows Single Quoted Object Keys When Enabled`() throws {
      let json = "{'key':1}"
      let values = try json.utf8.partials(
        initialValue: [String: Int](),
        from: .json(
          configuration: JSONStreamParserConfiguration(syntaxOptions: [.singleQuotedStrings])
        )
      )
      expectNoDifference(values.last, ["key": 1])
    }

    @Test
    func `Allows Unquoted Keys When Enabled`() throws {
      let json = "{value:1}"
      let values = try json.utf8.partials(
        initialValue: [String: Int](),
        from: .json(configuration: JSONStreamParserConfiguration(syntaxOptions: [.unquotedKeys]))
      )
      expectNoDifference(values.last, ["value": 1])
    }

    @Test
    func `Allows Leading Plus When Enabled`() throws {
      let json = "+1"
      let values = try json.utf8.partials(
        initialValue: 0,
        from: .json(configuration: JSONStreamParserConfiguration(syntaxOptions: [.leadingPlus]))
      )
      expectNoDifference(values.last, 1)
    }

    @Test
    func `Allows Leading Zeros When Enabled`() throws {
      let json = "01"
      let values = try json.utf8.partials(
        initialValue: 0,
        from: .json(configuration: JSONStreamParserConfiguration(syntaxOptions: [.leadingZeros]))
      )
      expectNoDifference(values.last, 1)
    }

    @Test
    func `Allows Hex Numbers When Enabled`() throws {
      let json = "0x1f"
      let values = try json.utf8.partials(
        initialValue: 0,
        from: .json(configuration: JSONStreamParserConfiguration(syntaxOptions: [.hexNumbers]))
      )
      expectNoDifference(values.last, 31)
    }

    @Test
    func `Allows Leading Decimal Point When Enabled`() throws {
      let json = ".125"
      let values = try json.utf8.partials(
        initialValue: 0.0,
        from: .json(
          configuration: JSONStreamParserConfiguration(syntaxOptions: [.leadingDecimalPoint])
        )
      )
      expectNoDifference(values.last, 0.125)
    }

    @Test
    func `Allows Non Finite Numbers When Enabled`() throws {
      let json = "Infinity"
      let values = try json.utf8.partials(
        initialValue: 0.0,
        from: .json(
          configuration: JSONStreamParserConfiguration(syntaxOptions: [.nonFiniteNumbers])
        )
      )
      expectNoDifference(values.last, Double.infinity)
    }

    @Test
    func `Allows NaN When Enabled`() throws {
      let json = "NaN"
      let values = try json.utf8.partials(
        initialValue: 0.0,
        from: .json(
          configuration: JSONStreamParserConfiguration(syntaxOptions: [.nonFiniteNumbers])
        )
      )
      #expect(values.last?.isNaN == true)
    }

    @Test
    func `Allows Control Characters In Strings When Enabled`() throws {
      let json = "\"\u{0001}\""
      let values = try json.utf8.partials(
        initialValue: "",
        from: .json(
          configuration: JSONStreamParserConfiguration(syntaxOptions: [.controlCharactersInStrings])
        )
      )
      expectNoDifference(values.last, "\u{0001}")
    }

    @Test
    func `Allows Comments And Unquoted Keys Together`() throws {
      let json = "{/*note*/unquoted:1}"
      let values = try json.utf8.partials(
        initialValue: [String: Int](),
        from: .json(
          configuration: JSONStreamParserConfiguration(syntaxOptions: [.comments, .unquotedKeys])
        )
      )
      expectNoDifference(values.last, ["unquoted": 1])
    }

    @Test
    func `Allows Comments And Trailing Commas Together`() throws {
      let json = "[1,/*note*/2,]"
      let values = try json.utf8.partials(
        initialValue: [Int](),
        from: .json(
          configuration: JSONStreamParserConfiguration(syntaxOptions: [.comments, .trailingCommas])
        )
      )
      expectNoDifference(values.last, [1, 2])
    }

    @Test
    func `Allows Unquoted Keys And Single Quoted Strings Together`() throws {
      let json = "{unquoted:'value'}"
      let values = try json.utf8.partials(
        initialValue: [String: String](),
        from: .json(
          configuration: JSONStreamParserConfiguration(
            syntaxOptions: [.unquotedKeys, .singleQuotedStrings]
          )
        )
      )
      expectNoDifference(values.last, ["unquoted": "value"])
    }
  }
}

private func expectJSONStreamedValues<T: StreamParseableValue & Equatable>(
  _ json: String,
  configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration(),
  initialValue: T,
  expected: [T],
  file: StaticString = #fileID,
  line: UInt = #line
) throws {
  let values = try json.utf8.partials(
    initialValue: initialValue,
    from: .json(configuration: configuration)
  )
  expectNoDifference(values, expected, fileID: file, line: line)
}

private func expectJSONStreamedValuesBeforeError<T: StreamParseableValue & Equatable>(
  _ json: String,
  configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration(),
  initialValue: T,
  expected: [T],
  reason: JSONStreamParsingError.Reason
) {
  var stream = PartialsStream(initialValue: initialValue, from: .json(configuration: configuration))
  var partials = [T]()
  let thrownError = #expect(throws: JSONStreamParsingError.self) {
    for byte in json.utf8 {
      partials.append(try stream.next(byte))
    }
    _ = try stream.finish()
  }

  guard let error = thrownError else {
    Issue.record("Expected JSONStreamParsingError to be captured.")
    return
  }
  #expect(error.reason == reason)
  expectNoDifference(partials, expected)
}

private func expectJSONStreamParsingError<T: StreamParseableValue>(
  _ json: String,
  configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration(),
  initialValue: T,
  reason: JSONStreamParsingError.Reason,
  position: JSONStreamParsingPosition? = nil
) {
  let thrownError = #expect(throws: JSONStreamParsingError.self) {
    _ = try json.utf8.partials(
      initialValue: initialValue,
      from: .json(configuration: configuration)
    )
  }

  guard let error = thrownError else {
    Issue.record("Expected JSONStreamParsingError to be captured.")
    return
  }
  #expect(error.reason == reason)
  if let position {
    #expect(error.position == position)
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

@StreamParseable(partialMembers: .initialParseableValue)
struct InitialParseableNestedValue: Equatable {
  var value: Int = 0
}

@StreamParseable(partialMembers: .initialParseableValue)
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
  var values: [String: Int]
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
struct `JSONKeyDecodingStrategy tests` {
  @Test(
    arguments: [
      ("", ""),
      ("simple_key", "simpleKey"),
      ("more_complex_snake_case_value", "moreComplexSnakeCaseValue"),
      ("alreadyCamelCase", "alreadyCamelCase"),
      ("_", "_"),
      ("___", "___"),
      ("1_value", "1Value"),
      ("snake__case", "snakeCase"),
      ("snake_case__", "snakeCase__"),
      ("snake_case_with_123", "snakeCaseWith123")
    ]
  )
  func `ConvertFromSnakeCase Converts Snake Cased Keys`(
    input: String,
    expected: String
  ) throws {
    let strategy = JSONKeyDecodingStrategy.convertFromSnakeCase
    expectNoDifference(strategy.decode(key: input), expected)
  }
}

@Suite
struct `JSONDump tests` {
  private let url64Kb = Bundle.module.url(forResource: "64KB", withExtension: "json")!
  private let url512Kb = Bundle.module.url(forResource: "512KB", withExtension: "json")!
  private let urlDeepNested64 = Bundle.module.url(forResource: "DeepNested64", withExtension: "json")!

  @Test
  func `Small JSON Dump Optional`() throws {
    try self.assertSnapshot(of: [ProfileOptional.Partial].self, from: self.url64Kb)
  }

  @Test
  func `Small JSON Dump Parseable`() throws {
    try self.assertSnapshot(of: [ProfileParseable.Partial].self, from: self.url64Kb)
  }

  @Test
  func `Large JSON Dump Optional`() throws {
    try self.assertSnapshot(of: [ProfileOptional.Partial].self, from: self.url512Kb)
  }

  @Test
  func `Large JSON Dump Parseable`() throws {
    try self.assertSnapshot(of: [ProfileParseable.Partial].self, from: self.url512Kb)
  }

  @Test
  func `Nested JSON Dump Partial States`() throws {
    try self.assertNestedPartialSnapshot(
      from: self.urlDeepNested64,
      chunkSize: 256 * 1024,
      testName: #function
    )
  }

  private func assertSnapshot<Value: StreamParseableValue & Encodable>(
    of type: Value.Type,
    from url: URL,
    testName: String = #function
  ) throws {
    let data = try Data(contentsOf: url)
    var stream = PartialsStream(initialValue: type.initialParseableValue(), from: .json())
    for byte in data {
      _ = try stream.next(byte)
    }
    let final = try stream.finish()
    SnapshotTesting.assertSnapshot(of: final, as: .json, testName: testName)
  }

  private func assertNestedPartialSnapshot(
    from url: URL,
    chunkSize: Int,
    testName: String
  ) throws {
    let data = try Data(contentsOf: url)
    var stream = PartialsStream(
      initialValue: DeepNestedRoot.Partial.initialParseableValue(),
      from: .json()
    )
    let bytes = Array(data)
    var partials = [DeepNestedRoot.Partial]()
    var offset = bytes.startIndex

    while offset < bytes.endIndex {
      let endIndex = min(offset + chunkSize, bytes.endIndex)
      partials.append(try stream.next(bytes[offset..<endIndex]))
      offset = endIndex
    }

    partials.append(try stream.finish())
    SnapshotTesting.assertSnapshot(of: partials, as: .json, testName: testName)
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

@StreamParseable(partialMembers: .initialParseableValue)
struct ProfileParseable {
  var id: String
  var name: String
  var language: String
  var bio: String
  var version: Double
}

extension ProfileParseable.Partial: Codable {}

