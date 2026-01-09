import CustomDump
import Foundation
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
    func `Streams JSON String With Square Brackets Inside`() throws {
      let json = "\"[]\""
      let expected = ["", "[", "[]", "[]", "[]"]
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
    func `Streams JSON Negative Sign Only`() throws {
      let json = "-"
      let expected: [Int] = [0, 0]
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
      let fractionalHolding = Array(
        repeating: ["fractional": 12.34],
        count: 15
      )
      let exponentialPhase: [[String: Double]] = [
        ["fractional": 12.34, "exponential": 1],
        ["fractional": 12.34, "exponential": 12],
        ["fractional": 12.34, "exponential": 12],
        ["fractional": 12.34, "exponential": 12_000],
        ["fractional": 12.34, "exponential": 12_000],
        ["fractional": 12.34, "exponential": 12_000]
      ]
      let expected = stageOne + fractionalProgress + fractionalHolding + exponentialPhase
      try expectJSONStreamedValues(json, initialValue: [String: Double](), expected: expected)
    }

    @Test
    func `Streams JSON Object With Nullable Value Into StreamParseable Struct`() throws {
      let json = "{\"maybe\":null}"
      let beforeNull = Array(repeating: NullableObject.Partial(), count: 12)
      let afterNull = Array(
        repeating: NullableObject.Partial(maybe: Optional<Int?>.some(nil)),
        count: 3
      )
      let expected = beforeNull + afterNull
      try expectJSONStreamedValues(json, initialValue: NullableObject.Partial(), expected: expected)
    }

    @Test
    func `Streams JSON Object With Nullable Value Into Dictionary`() throws {
      let json = "{\"maybe\":null}"
      let beforeNull = Array(repeating: [String: Int?](), count: 12)
      let afterNull = Array(
        repeating: ["maybe": nil] as [String: Int?],
        count: 3
      )
      let expected = beforeNull + afterNull
      try expectJSONStreamedValues(json, initialValue: [String: Int?](), expected: expected)
    }

    @Test
    func `Streams JSON Empty Object Into StreamParseable Struct`() throws {
      let json = "{}"
      let expected = Array(repeating: EmptyObject.Partial(), count: 3)
      try expectJSONStreamedValues(json, initialValue: EmptyObject.Partial(), expected: expected)
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

    @Test
    func `Streams JSON True From T`() throws {
      try expectJSONStreamedValues("t", initialValue: false, expected: [true, true])
    }

    @Test
    func `Streams JSON False From F`() throws {
      try expectJSONStreamedValues("f", initialValue: true, expected: [false, false])
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

    @Test
    func `Streams JSON Null From N`() throws {
      let expected: [String?] = [nil, nil]
      try expectJSONStreamedValues("n", initialValue: "seed", expected: expected)
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

@StreamParseable
struct TwoKeyObject: Equatable {
  var first: Int = 0
  var second: Int = 0
}

@StreamParseable
struct NestedValue: Equatable {
  var value: Int = 0
}

@StreamParseable
struct NestedContainer: Equatable {
  var nested: NestedValue = .init()
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
struct EmptyObject: Equatable {}

extension TwoKeyObject.Partial: Equatable {}
extension NestedValue.Partial: Equatable {}
extension NestedContainer.Partial: Equatable {}
extension DoubleNestedLevel2.Partial: Equatable {}
extension DoubleNestedLevel1.Partial: Equatable {}
extension DoubleNestedRoot.Partial: Equatable {}
extension NullableObject.Partial: Equatable {}
extension EmptyObject.Partial: Equatable {}

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
