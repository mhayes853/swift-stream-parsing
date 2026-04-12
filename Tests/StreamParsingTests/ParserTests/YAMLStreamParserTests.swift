import CustomDump
import Foundation
import SnapshotTesting
import StreamParsing
import Testing
import Yams

extension Snapshotting where Value: Encodable, Format == String {
  static var yaml: SnapshotTesting.Snapshotting<Value, String> {
    Snapshotting(
      pathExtension: "yaml",
      diffing: .lines,
      snapshot: { value in
        try! YAMLEncoder().encode(value)
      }
    )
  }
}

@Suite
struct `YAMLStreamParser tests` {
  @Suite
  struct `YAMLString tests` {
    @Test
    func `Streams YAML String Characters`() throws {
      let yaml = "\"Blob\""
      let expected = ["", "B", "Bl", "Blo", "Blob", "Blob", "Blob"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML Empty String`() throws {
      let yaml = "\"\""
      let expected = ["", "", ""]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Escaped Quote`() throws {
      let yaml = "\"\\\"\""
      let expected = ["", "", "\"", "\"", "\""]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Escaped Backslash`() throws {
      let yaml = "\"\\\\\""
      let expected = ["", "", "\\", "\\", "\\"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Escaped Newline`() throws {
      let yaml = "\"line\\nend\""
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
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Escaped Tab`() throws {
      let yaml = "\"\\t\""
      let expected = ["", "", "\t", "\t", "\t"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Emoji`() throws {
      let yaml = "\"😀\""
      let expected = ["", "", "", "", "😀", "😀", "😀"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Multiple Emojis`() throws {
      let yaml = "\"😀😃\""
      let expected = ["", "", "", "", "😀", "😀", "😀", "😀", "😀😃", "😀😃", "😀😃"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Escaped Backspace`() throws {
      let yaml = "\"\\b\""
      let expected = ["", "", "\u{08}", "\u{08}", "\u{08}"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Escaped Form Feed`() throws {
      let yaml = "\"\\f\""
      let expected = ["", "", "\u{0C}", "\u{0C}", "\u{0C}"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Escaped Carriage Return`() throws {
      let yaml = "\"\\r\""
      let expected = ["", "", "\r", "\r", "\r"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Escaped Slash`() throws {
      let yaml = "\"\\/\""
      let expected = ["", "", "/", "/", "/"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Square Brackets Inside`() throws {
      let yaml = "\"[]\""
      let expected = ["", "[", "[]", "[]", "[]"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String Containing Only Numbers`() throws {
      let yaml = "\"123\""
      let expected = ["", "1", "12", "123", "123", "123"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Two-Byte Character`() throws {
      let yaml = "\"\u{00E9}\""
      let expected = ["", "", "\u{00E9}", "\u{00E9}", "\u{00E9}"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Four-Byte NonEmoji Character`() throws {
      let yaml = "\"\u{1D11E}\""
      let expected = ["", "", "", "", "\u{1D11E}", "\u{1D11E}", "\u{1D11E}"]
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML String With Consecutive Four-Byte Scalars`() throws {
      let scalar1 = "\u{10437}"
      let scalar2 = "\u{10438}"
      let yaml = "\"\(scalar1)\(scalar2)\""
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
      try expectYAMLStreamedValues(yaml, initialValue: "", expected: expected)
    }

    @Test
    func `Streams YAML Literal Block String`() throws {
      let yaml = """
      |
        hello
        world
      """
      try expectYAMLFinalValue(yaml, initialValue: "", expected: "hello\nworld")
    }

    @Test
    func `Streams YAML Folded Block String`() throws {
      let yaml = """
      >
        hello
        world
      """
      try expectYAMLFinalValue(yaml, initialValue: "", expected: "hello world")
    }

    @Test
    func `Streams YAML Literal Block String With Blank Line And Extra Indentation`() throws {
      let yaml = """
      |
        hello

          world
      """
      try expectYAMLFinalValue(yaml, initialValue: "", expected: "hello\n\n  world")
    }

    @Test
    func `Streams YAML Folded Block String With Blank Line`() throws {
      let yaml = """
      >
        hello

        world
      """
      try expectYAMLFinalValue(yaml, initialValue: "", expected: "hello\n\nworld")
    }

    @Test
    func `Streams YAML Folded Block String With Extra Indentation`() throws {
      let yaml = """
      >
        hello
          world
      """
      try expectYAMLFinalValue(yaml, initialValue: "", expected: "hello   world")
    }
  }

  @Suite
  struct `YAMLNumber tests` {
    @Test
    func `Streams YAML Integer Digits`() throws {
      let yaml = "1234"
      let expected = [1, 12, 123, 1234, 1234]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Zero Integer`() throws {
      let yaml = "0"
      let expected = [0, 0]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Negative Integer Digits`() throws {
      let yaml = "-123"
      let expected = [0, -1, -12, -123, -123]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Double Zero With Trailing Decimal`() throws {
      let yaml = "0.0"
      let expected: [Double] = [0, 0, 0, 0]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Float Zero With Trailing Decimal`() throws {
      let yaml = "0.0"
      let expected: [Float] = [0, 0, 0, 0]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Double Digits`() throws {
      let yaml = "12.34"
      let expected: [Double] = [1, 12, 12, 12.3, 12.34, 12.34]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Negative Double Digits`() throws {
      let yaml = "-12.34"
      let expected: [Double] = [0, -1, -12, -12, -12.3, -12.34, -12.34]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Float Digits`() throws {
      let yaml = "12.34"
      let expected: [Float] = [1, 12, 12, 12.3, 12.34, 12.34]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Double Exponent Digits`() throws {
      let yaml = "12e3"
      let expected: [Double] = [1, 12, 12, 12, 12_000]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Double Negative Exponent Digits`() throws {
      let yaml = "12e-3"
      let expected: [Double] = [1, 12, 12, 12, 12, 0.012]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Double Positive Exponent Digits`() throws {
      let yaml = "12e+3"
      let expected: [Double] = [1, 12, 12, 12, 12, 12_000]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Double Uppercase Exponent Digits`() throws {
      let yaml = "12E3"
      let expected: [Double] = [1, 12, 12, 12, 12_000]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Double Large Positive Exponent Digits`() throws {
      let yaml = "12e21"
      let expected = 1.2e22
      let values = try yaml.utf8.partials(initialValue: 0.0, from: .yaml())
      expectClose(try #require(values.last), expected, epsilon: 1e7)
    }

    @Test
    func `Streams YAML Double Large Negative Exponent Digits`() throws {
      let yaml = "12e-21"
      let expected = 1.2e-20
      let values = try yaml.utf8.partials(initialValue: 0.0, from: .yaml())
      expectClose(try #require(values.last), expected, epsilon: 1e-30)
    }

    @Test
    func `Streams YAML Double Positive Zero Exponent Digits`() throws {
      let yaml = "12e+0"
      let expected: [Double] = [1, 12, 12, 12, 12, 12]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Double Negative Zero Exponent Digits`() throws {
      let yaml = "12e-0"
      let expected: [Double] = [1, 12, 12, 12, 12, 12]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Float Exponent Digits`() throws {
      let yaml = "12e3"
      let expected: [Float] = [1, 12, 12, 12, 12_000]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Float Positive Exponent Digits`() throws {
      let yaml = "12e+3"
      let expected: [Float] = [1, 12, 12, 12, 12, 12_000]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Float Uppercase Exponent Digits`() throws {
      let yaml = "12E3"
      let expected: [Float] = [1, 12, 12, 12, 12_000]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Double With Trailing Decimal Zero`() throws {
      let yaml = "11.0"
      let expected: [Double] = [1, 11, 11, 11, 11]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Float With Trailing Decimal Zero`() throws {
      let yaml = "11.0"
      let expected: [Float] = [1, 11, 11, 11, 11]
      try expectYAMLStreamedValues(yaml, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams YAML Large Integer Digits`() throws {
      let yaml = "18446744073709551615"
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
      try expectYAMLStreamedValues(yaml, initialValue: UInt64(0), expected: expected)
    }

    @Test
    func `Streams YAML Large Negative Integer Digits`() throws {
      let yaml = "-9223372036854775807"
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
      try expectYAMLStreamedValues(yaml, initialValue: Int64(0), expected: expected)
    }

    @Test
    @available(StreamParsing128BitIntegers, *)
    func `Streams YAML Large UInt128 Digits`() throws {
      let yaml = "340282366920938463463374607431768211455"
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
      try expectYAMLStreamedValues(yaml, initialValue: UInt128(0), expected: expected)
    }

    @Test
    @available(StreamParsing128BitIntegers, *)
    func `Streams YAML Large Negative Int128 Digits`() throws {
      let yaml = "-170141183460469231731687303715884105727"
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
      try expectYAMLStreamedValues(yaml, initialValue: Int128(0), expected: expected)
    }
  }

  @Suite
  struct `YAMLBoolean tests` {
    @Test
    func `Streams YAML True`() throws {
      let yaml = "true"
      let expected = [true, true, true, true, true]
      try expectYAMLStreamedValues(yaml, initialValue: false, expected: expected)
    }

    @Test
    func `Streams YAML False`() throws {
      let yaml = "false"
      let expected = [false, false, false, false, false, false]
      try expectYAMLStreamedValues(yaml, initialValue: true, expected: expected)
    }
  }

  @Suite
  struct `YAMLNull tests` {
    @Test
    func `Streams YAML Null`() throws {
      let yaml = "null"
      let expected: [String?] = [nil, nil, nil, nil, nil]
      try expectYAMLStreamedValues(yaml, initialValue: "seed", expected: expected)
    }
  }

  @Suite
  struct `YAMLArray tests` {
    @Test
    func `Streams YAML Integer Array`() throws {
      let yaml = "[1,2]"
      let expected: [[Int]] = [
        [],
        [1],
        [1],
        [1, 2],
        [1, 2],
        [1, 2]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [Int](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Integer Array`() throws {
      let yaml = """
      - 1
      - 2
      """
      let expected: [[Int]] = [
        [],
        [],
        [1],
        [1],
        [1],
        [1],
        [1, 2],
        [1, 2]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [Int](), expected: expected)
    }

    @Test
    func `Streams YAML Integer Array With Heavy Whitespace`() throws {
      let yaml = "[  1    ,    2   ]"
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
      try expectYAMLStreamedValues(yaml, initialValue: [Int](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Integer Array With Heavy Whitespace`() throws {
      let yaml = """
      -   1
      -   2
      """
      let expected: [[Int]] = [
        [],
        [],
        [],
        [],
        [1],
        [1],
        [1],
        [1],
        [1],
        [1],
        [1, 2],
        [1, 2]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [Int](), expected: expected)
    }

    @Test
    func `Streams YAML Array With Fractional And Exponential Double`() throws {
      let yaml = "[12.34,12e3]"
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
      try expectYAMLStreamedValues(yaml, initialValue: [Double](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Array With Fractional And Exponential Double`() throws {
      let yaml = """
      - 12.34
      - 12e3
      """
      let expected: [[Double]] = [
        [],
        [],
        [1],
        [12],
        [12],
        [12.3],
        [12.34],
        [12.34],
        [12.34],
        [12.34],
        [12.34, 1],
        [12.34, 12],
        [12.34, 12],
        [12.34, 12],
        [12.34, 12_000]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [Double](), expected: expected)
    }

    @Test
    func `Streams YAML Integer 2D Array`() throws {
      let yaml = "[[1],[2]]"
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
      try expectYAMLStreamedValues(yaml, initialValue: [[Int]](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Integer 2D Array`() throws {
      let yaml = """
      -
        - 1
      -
        - 2
      """
      let expected: [[[Int]]] = [
        [],
        [],
        [],
        [],
        [],
        [[]],
        [[1]],
        [[1]],
        [[1]],
        [[1]],
        [[1]],
        [[1]],
        [[1]],
        [[1], []],
        [[1], [2]],
        [[1], [2]]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [[Int]](), expected: expected)
    }

    @Test
    func `Streams YAML String Array`() throws {
      let yaml = "[\"a\",\"b\"]"
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
      try expectYAMLStreamedValues(yaml, initialValue: [String](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style String Array`() throws {
      let yaml = """
      - "a"
      - "b"
      """
      let expected: [[String]] = [
        [],
        [],
        [""],
        ["a"],
        ["a"],
        ["a"],
        ["a"],
        ["a"],
        ["a", ""],
        ["a", "b"],
        ["a", "b"],
        ["a", "b"]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [String](), expected: expected)
    }

    @Test
    func `Streams YAML String 2D Array`() throws {
      let yaml = "[[\"a\"],[\"b\"]]"
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
      try expectYAMLStreamedValues(yaml, initialValue: [[String]](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style String 2D Array`() throws {
      let yaml = """
      -
        - "a"
      -
        - "b"
      """
      let expected: [[[String]]] = [
        [],
        [],
        [],
        [],
        [],
        [[]],
        [[""]],
        [["a"]],
        [["a"]],
        [["a"]],
        [["a"]],
        [["a"]],
        [["a"]],
        [["a"]],
        [["a"]],
        [["a"], []],
        [["a"], [""]],
        [["a"], ["b"]],
        [["a"], ["b"]],
        [["a"], ["b"]]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [[String]](), expected: expected)
    }

    @Test
    func `Streams YAML Boolean Array`() throws {
      let yaml = "[true,false]"
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
      try expectYAMLStreamedValues(yaml, initialValue: [Bool](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Boolean Array`() throws {
      let yaml = """
      - true
      - false
      """
      let expected: [[Bool]] = [
        [],
        [],
        [true],
        [true],
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
        [true, false]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [Bool](), expected: expected)
    }

    @Test
    func `Streams YAML Boolean 2D Array`() throws {
      let yaml = "[[true],[false]]"
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
      try expectYAMLStreamedValues(yaml, initialValue: [[Bool]](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Boolean 2D Array`() throws {
      let yaml = """
      -
        - true
      -
        - false
      """
      let expected: [[[Bool]]] = [
        [],
        [],
        [],
        [],
        [],
        [[]],
        [[true]],
        [[true]],
        [[true]],
        [[true]],
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
        [[true], [false]]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [[Bool]](), expected: expected)
    }

    @Test
    func `Streams YAML Optional Array`() throws {
      let yaml = "[1,null]"
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
      try expectYAMLStreamedValues(yaml, initialValue: [Int?](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Optional Array`() throws {
      let yaml = """
      - 1
      - null
      """
      let expected: [[Int?]] = [
        [],
        [],
        [1],
        [1],
        [1],
        [1],
        [1, nil],
        [1, nil],
        [1, nil],
        [1, nil],
        [1, nil]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [Int?](), expected: expected)
    }

    @Test
    func `Streams YAML Optional 2D Array`() throws {
      let yaml = "[[null],[1]]"
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
      try expectYAMLStreamedValues(yaml, initialValue: [[Int?]](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Optional 2D Array`() throws {
      let yaml = """
      -
        - null
      -
        - 1
      """
      let expected: [[[Int?]]] = [
        [],
        [],
        [],
        [],
        [],
        [[]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil]],
        [[nil], []],
        [[nil], [1]],
        [[nil], [1]]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [[Int?]](), expected: expected)
    }

    @Test
    func `Streams YAML Integer 3D Array Single Element`() throws {
      let yaml = "[[[1]]]"
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
      try expectYAMLStreamedValues(yaml, initialValue: [[[Int]]](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Integer 3D Array Single Element`() throws {
      let yaml = """
      -
        -
          - 1
      """
      let expected: [[[[Int]]]] = [
        [],
        [],
        [],
        [],
        [],
        [[]],
        [[]],
        [[]],
        [[]],
        [[]],
        [[]],
        [[[]]],
        [[[1]]],
        [[[1]]]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [[[Int]]](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Array Containing Literal Arrays`() throws {
      let yaml = """
      - [1]
      - [2]
      """
      let expected: [[[Int]]] = [
        [],
        [],
        [[]],
        [[1]],
        [[1]],
        [[1]],
        [[1]],
        [[1]],
        [[1], []],
        [[1], [2]],
        [[1], [2]],
        [[1], [2]]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [[Int]](), expected: expected)
    }
  }

  @Suite
  struct `YAMLObject tests` {
    @Test
    func `Streams YAML Empty Object Into Dictionary`() throws {
      let yaml = "{}"
      let expected: [[String: Int]] = [[:], [:], [:]]
      try expectYAMLStreamedValues(yaml, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams YAML Object With Single Key Into Dictionary`() throws {
      let yaml = "{single: 1}"
      let expected: [[String: Int]] = [
        [:],
        [:],
        [:],
        [:],
        [:],
        [:],
        [:],
        [:],
        [:],
        ["single": 1],
        ["single": 1],
        ["single": 1]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Object With Single Key Into Dictionary`() throws {
      let yaml = "single: 1"
      let expected: [[String: Int]] = [
        [:],
        [:],
        [:],
        [:],
        [:],
        [:],
        [:],
        [:],
        ["single": 1],
        ["single": 1]
      ]
      try expectYAMLStreamedValues(yaml, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams YAML Object With Two Keys Into Dictionary`() throws {
      let yaml = "{first: 1, second: 2}"
      let initial = Array(repeating: [String: Int](), count: 8)
      let firstPhase = Array(repeating: ["first": 1], count: 11)
      let finalPhase = Array(repeating: ["first": 1, "second": 2], count: 3)
      let expected: [[String: Int]] = initial + firstPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Object With Two Keys Into Dictionary`() throws {
      let yaml = """
      first: 1
      second: 2
      """
      let initialPhase: [[String: Int]] = Array(repeating: [:], count: 7)
      let firstPhase: [[String: Int]] = Array(repeating: ["first": 1], count: 10)
      let finalPhase: [[String: Int]] = Array(repeating: ["first": 1, "second": 2], count: 2)
      let expected: [[String: Int]] = initialPhase + firstPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams YAML Object With Two Keys Into StreamParseable Struct`() throws {
      let yaml = "{first: 1, second: 2}"
      let initialPhase: [TwoKeyObject.Partial] = Array(repeating: TwoKeyObject.Partial(), count: 8)
      let firstPhase: [TwoKeyObject.Partial] = Array(repeating: TwoKeyObject.Partial(first: 1, second: nil), count: 11)
      let finalPhase: [TwoKeyObject.Partial] = Array(repeating: TwoKeyObject.Partial(first: 1, second: 2), count: 3)
      let expected = initialPhase + firstPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: TwoKeyObject.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Object With Two Keys Into StreamParseable Struct`() throws {
      let yaml = """
      first: 1
      second: 2
      """
      let initialPhase: [TwoKeyObject.Partial] = Array(repeating: TwoKeyObject.Partial(), count: 7)
      let firstPhase: [TwoKeyObject.Partial] = Array(repeating: TwoKeyObject.Partial(first: 1, second: nil), count: 10)
      let finalPhase: [TwoKeyObject.Partial] = Array(repeating: TwoKeyObject.Partial(first: 1, second: 2), count: 2)
      let expected = initialPhase + firstPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: TwoKeyObject.Partial(), expected: expected)
    }

    @Test
    func `Continues Parsing YAML Flow-Style Mapping After Ignored Key`() throws {
      let yaml = "{ignored: \"alpha\", tracked: \"beta\"}"
      let nilPhase: [TrackedOnly.Partial] = Array(repeating: TrackedOnly.Partial(tracked: nil), count: 28)
      let stringPhase: [TrackedOnly.Partial] = [
        TrackedOnly.Partial(tracked: ""),
        TrackedOnly.Partial(tracked: "b"),
        TrackedOnly.Partial(tracked: "be"),
        TrackedOnly.Partial(tracked: "bet"),
        TrackedOnly.Partial(tracked: "beta"),
        TrackedOnly.Partial(tracked: "beta"),
        TrackedOnly.Partial(tracked: "beta"),
        TrackedOnly.Partial(tracked: "beta")
      ]
      let expected = nilPhase + stringPhase
      try expectYAMLStreamedValues(yaml, initialValue: TrackedOnly.Partial(), expected: expected)
    }

    @Test
    func `Continues Parsing YAML Block-Style Mapping After Ignored Key`() throws {
      let yaml = """
      ignored: "alpha"
      tracked: "beta"
      """
      let nilPhase: [TrackedOnly.Partial] = Array(repeating: TrackedOnly.Partial(tracked: nil), count: 26)
      let stringPhase: [TrackedOnly.Partial] = [
        TrackedOnly.Partial(tracked: ""),
        TrackedOnly.Partial(tracked: "b"),
        TrackedOnly.Partial(tracked: "be"),
        TrackedOnly.Partial(tracked: "bet"),
        TrackedOnly.Partial(tracked: "beta"),
        TrackedOnly.Partial(tracked: "beta"),
        TrackedOnly.Partial(tracked: "beta")
      ]
      let expected = nilPhase + stringPhase
      try expectYAMLStreamedValues(yaml, initialValue: TrackedOnly.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Nested Object Into Dictionary Of Dictionaries`() throws {
      let yaml = "{outer: {inner: 1}}"
      let initialPhase: [[String: [String: Int]]] = Array(repeating: [:], count: 8)
      let outerPhase: [[String: [String: Int]]] = Array(repeating: ["outer": [:]], count: 8)
      let finalPhase: [[String: [String: Int]]] = Array(repeating: ["outer": ["inner": 1]], count: 4)
      let expected = initialPhase + outerPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: [String: [String: Int]](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Nested Object Into Dictionary Of Dictionaries`() throws {
      let yaml = """
      outer:
        inner: 1
      """
      let initialPhase: [[String: [String: Int]]] = Array(repeating: [:], count: 9)
      let outerPhase: [[String: [String: Int]]] = Array(repeating: ["outer": [:]], count: 7)
      let finalPhase: [[String: [String: Int]]] = Array(repeating: ["outer": ["inner": 1]], count: 2)
      let expected = initialPhase + outerPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: [String: [String: Int]](), expected: expected)
    }

    @Test
    func `Streams YAML Nested Object Into StreamParseable Struct`() throws {
      let yaml = "{nested: {value: 1}}"
      let nilPhase: [NestedContainer.Partial] = Array(repeating: NestedContainer.Partial(), count: 17)
      let finalPhase: [NestedContainer.Partial] = Array(repeating: NestedContainer.Partial(nested: NestedValue.Partial(value: 1)), count: 4)
      let expected = nilPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: NestedContainer.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Nested Object Into StreamParseable Struct`() throws {
      let yaml = """
      nested:
        value: 1
      """
      let nilPhase: [NestedContainer.Partial] = Array(repeating: NestedContainer.Partial(), count: 17)
      let finalPhase: [NestedContainer.Partial] = Array(repeating: NestedContainer.Partial(nested: NestedValue.Partial(value: 1)), count: 2)
      let expected = nilPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: NestedContainer.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Object With Nullable Value Into Dictionary`() throws {
      let yaml = "{maybe: null}"
      let initialPhase: [[String: Int?]] = Array(repeating: [:], count: 8)
      let finalPhase: [[String: Int?]] = Array(repeating: ["maybe": nil], count: 6)
      let expected = initialPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: [String: Int?](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Object With Nullable Value Into Dictionary`() throws {
      let yaml = "maybe: null"
      let initialPhase: [[String: Int?]] = Array(repeating: [:], count: 7)
      let finalPhase: [[String: Int?]] = Array(repeating: ["maybe": nil], count: 5)
      let expected = initialPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: [String: Int?](), expected: expected)
    }

    @Test
    func `Streams YAML Object With Fractional And Exponential Doubles Into Dictionary`() throws {
      let yaml = "{fractional: 12.34, exponential: 12e3}"
      let initialPhase: [[String: Double]] = Array(repeating: [:], count: 13)
      let fractionalBuildUp: [[String: Double]] = [
        ["fractional": 1.0],
        ["fractional": 12.0],
        ["fractional": 12.0],
        ["fractional": 12.3],
        ["fractional": 12.34]
      ]
      let fractionalStable: [[String: Double]] = Array(repeating: ["fractional": 12.34], count: 15)
      let expBuildUp: [[String: Double]] = [
        ["fractional": 12.34, "exponential": 1.0],
        ["fractional": 12.34, "exponential": 12.0],
        ["fractional": 12.34, "exponential": 12.0],
        ["fractional": 12.34, "exponential": 12.0],
        ["fractional": 12.34, "exponential": 12000.0]
      ]
      let final: [[String: Double]] = Array(repeating: ["fractional": 12.34, "exponential": 12000.0], count: 1)
      let expected = initialPhase + fractionalBuildUp + fractionalStable + expBuildUp + final
      try expectYAMLStreamedValues(yaml, initialValue: [String: Double](), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Object With Fractional And Exponential Doubles Into Dictionary`() throws {
      let yaml = """
      fractional: 12.34
      exponential: 12e3
      """
      let initialPhase: [[String: Double]] = Array(repeating: [:], count: 12)
      let fractionalBuildUp: [[String: Double]] = [
        ["fractional": 1.0],
        ["fractional": 12.0],
        ["fractional": 12.0],
        ["fractional": 12.3],
        ["fractional": 12.34]
      ]
      let fractionalStable: [[String: Double]] = Array(repeating: ["fractional": 12.34], count: 14)
      let expBuildUp: [[String: Double]] = [
        ["fractional": 12.34, "exponential": 1.0],
        ["fractional": 12.34, "exponential": 12.0],
        ["fractional": 12.34, "exponential": 12.0],
        ["fractional": 12.34, "exponential": 12.0],
        ["fractional": 12.34, "exponential": 12000.0]
      ]
      let expected = initialPhase + fractionalBuildUp + fractionalStable + expBuildUp
      try expectYAMLStreamedValues(yaml, initialValue: [String: Double](), expected: expected)
    }

    @Test
    func `Streams YAML Object With Nullable Value Into StreamParseable Struct`() throws {
      let yaml = "{maybe: null}"
      let nilPhase: [NullableObject.Partial] = Array(repeating: NullableObject.Partial(), count: 8)
      let finalPhase: [NullableObject.Partial] = Array(repeating: NullableObject.Partial(maybe: .some(nil)), count: 6)
      let expected = nilPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: NullableObject.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Object With Nullable Value Into StreamParseable Struct`() throws {
      let yaml = "maybe: null"
      let nilPhase: [NullableObject.Partial] = Array(repeating: NullableObject.Partial(), count: 7)
      let finalPhase: [NullableObject.Partial] = Array(repeating: NullableObject.Partial(maybe: .some(nil)), count: 5)
      let expected = nilPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: NullableObject.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Object With Nested Nullable Value Into StreamParseable Struct`() throws {
      let yaml = "{inner: {maybe: null}}"
      let nilPhase: [NullableNestedContainer.Partial] = Array(repeating: NullableNestedContainer.Partial(), count: 16)
      let finalPhase: [NullableNestedContainer.Partial] = Array(repeating: NullableNestedContainer.Partial(inner: NullableNestedValue.Partial(maybe: .some(nil))), count: 7)
      let expected = nilPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: NullableNestedContainer.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Object With Nested Nullable Value Into StreamParseable Struct`() throws {
      let yaml = """
      inner:
        maybe: null
      """
      let nilPhase: [NullableNestedContainer.Partial] = Array(repeating: NullableNestedContainer.Partial(), count: 16)
      let finalPhase: [NullableNestedContainer.Partial] = Array(repeating: NullableNestedContainer.Partial(inner: NullableNestedValue.Partial(maybe: .some(nil))), count: 5)
      let expected = nilPhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: NullableNestedContainer.Partial(), expected: expected)
    }

    @Test
    func `Parses Empty YAML Object From Boolean Property`() throws {
      let yaml = "{flag: true, other: {}}"
      let expected: [EmptyObject.Partial] = Array(repeating: EmptyObject.Partial(), count: 24)
      try expectYAMLStreamedValues(yaml, initialValue: EmptyObject.Partial(), expected: expected)
    }

    @Test
    func `Parses Empty YAML Object From Null Property`() throws {
      let yaml = "{value: null, other: {}}"
      let expected: [EmptyObject.Partial] = Array(repeating: EmptyObject.Partial(), count: 25)
      try expectYAMLStreamedValues(yaml, initialValue: EmptyObject.Partial(), expected: expected)
    }

    @Test
    func `Parses Empty YAML Object From Array Property`() throws {
      let yaml = "{values: [1, 2, 3], other: {}}"
      let expected: [EmptyObject.Partial] = Array(repeating: EmptyObject.Partial(), count: 31)
      try expectYAMLStreamedValues(yaml, initialValue: EmptyObject.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Object With Array Property Into StreamParseable Struct`() throws {
      let yaml = "{numbers: [1, 2]}"
      let nilPhase: [ArrayPropertyContainer.Partial] = Array(repeating: ArrayPropertyContainer.Partial(), count: 10)
      let emptyArray: [ArrayPropertyContainer.Partial] = [ArrayPropertyContainer.Partial(numbers: [])]
      let oneElement: [ArrayPropertyContainer.Partial] = Array(repeating: ArrayPropertyContainer.Partial(numbers: [1]), count: 3)
      let finalPhase: [ArrayPropertyContainer.Partial] = Array(repeating: ArrayPropertyContainer.Partial(numbers: [1, 2]), count: 4)
      let expected = nilPhase + emptyArray + oneElement + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: ArrayPropertyContainer.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Object With Array Property Into StreamParseable Struct`() throws {
      let yaml = """
      numbers:
        - 1
        - 2
      """
      let nilPhase: [ArrayPropertyContainer.Partial] = Array(repeating: ArrayPropertyContainer.Partial(), count: 12)
      let emptyArray: [ArrayPropertyContainer.Partial] = [ArrayPropertyContainer.Partial(numbers: [])]
      let oneElement: [ArrayPropertyContainer.Partial] = Array(repeating: ArrayPropertyContainer.Partial(numbers: [1]), count: 6)
      let finalPhase: [ArrayPropertyContainer.Partial] = Array(repeating: ArrayPropertyContainer.Partial(numbers: [1, 2]), count: 2)
      let expected = nilPhase + emptyArray + oneElement + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: ArrayPropertyContainer.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Object With Dictionary Property Into StreamParseable Struct`() throws {
      let yaml = "{values: {inner: 1}}"
      let nilPhase: [DictionaryPropertyContainer.Partial] = Array(repeating: DictionaryPropertyContainer.Partial(), count: 9)
      let emptyDict: [DictionaryPropertyContainer.Partial] = Array(repeating: DictionaryPropertyContainer.Partial(values: [:]), count: 8)
      let finalPhase: [DictionaryPropertyContainer.Partial] = Array(repeating: DictionaryPropertyContainer.Partial(values: ["inner": 1]), count: 4)
      let expected = nilPhase + emptyDict + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: DictionaryPropertyContainer.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Object With Dictionary Property Into StreamParseable Struct`() throws {
      let yaml = """
      values:
        inner: 1
      """
      let nilPhase: [DictionaryPropertyContainer.Partial] = Array(repeating: DictionaryPropertyContainer.Partial(), count: 10)
      let emptyDict: [DictionaryPropertyContainer.Partial] = Array(repeating: DictionaryPropertyContainer.Partial(values: [:]), count: 7)
      let finalPhase: [DictionaryPropertyContainer.Partial] = Array(repeating: DictionaryPropertyContainer.Partial(values: ["inner": 1]), count: 2)
      let expected = nilPhase + emptyDict + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: DictionaryPropertyContainer.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Object With Duplicate Keys Into Dictionary Keeping Last Value`() throws {
      let yaml = "{value: 1, value: 2}"
      let initialPhase: [[String: Int]] = Array(repeating: [:], count: 8)
      let firstValuePhase: [[String: Int]] = Array(repeating: ["value": 1], count: 10)
      let finalPhase: [[String: Int]] = Array(repeating: ["value": 2], count: 3)
      let expected = initialPhase + firstValuePhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams YAML Empty Object Into StreamParseable Struct`() throws {
      let yaml = "{}"
      let expected = Array(repeating: EmptyObject.Partial(), count: 3)
      try expectYAMLStreamedValues(yaml, initialValue: EmptyObject.Partial(), expected: expected)
    }

    @Test
    func `Streams YAML Block-Style Object With Duplicate Keys Into Dictionary Keeping Last Value`() throws {
      let yaml = """
      value: 1
      value: 2
      """
      let initialPhase: [[String: Int]] = Array(repeating: [:], count: 7)
      let firstValuePhase: [[String: Int]] = Array(repeating: ["value": 1], count: 9)
      let finalPhase: [[String: Int]] = Array(repeating: ["value": 2], count: 2)
      let expected = initialPhase + firstValuePhase + finalPhase
      try expectYAMLStreamedValues(yaml, initialValue: [String: Int](), expected: expected)
    }
  }

  @Suite
  struct `YAMLError tests` {
    @Test
    func `Throws For Missing Colon`() throws {
      let yaml = "{a 1}"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .missingColon
      )
    }

    @Test
    func `Throws For Unexpected Token In Neutral Mode`() throws {
      let yaml = "]["
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Unterminated String`() throws {
      let yaml = "\"unterminated"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: "",
        reason: .unterminatedString
      )
    }

    @Test
    func `Throws For Invalid Unicode Escape`() throws {
      let yaml = "\"\\u12\""
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: "",
        reason: .invalidUnicodeEscape
      )
    }

    @Test
    func `Throws For Invalid Literal`() throws {
      let yaml = "{a: truX}"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Bool](),
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Invalid Number`() throws {
      let yaml = "{a: -}"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Invalid Fractional Number`() throws {
      let yaml = "1."
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: 0.0,
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Invalid Exponent`() throws {
      let yaml = "1e+"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: 0.0,
        reason: .invalidExponent
      )
    }

    @Test
    func `Throws For Numeric Overflow`() throws {
      let yaml = "[18446744073709551616]"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [UInt64](),
        reason: .numericOverflow
      )
    }

    @Test
    func `Throws For Missing Value`() throws {
      let yaml = "{a: }"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .missingValue
      )
    }

    @Test
    func `Throws For Trailing Comma In Object`() throws {
      let yaml = "{a: 1,}"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .trailingComma
      )
    }

    @Test
    func `Throws For Trailing Comma In Array`() throws {
      let yaml = "[1,]"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [Int](),
        reason: .trailingComma
      )
    }

    @Test
    func `Throws For Missing Comma In Array`() throws {
      let yaml = "[1 2]"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [Int](),
        reason: .missingComma
      )
    }

    @Test
    func `Throws For Missing Closing Brace`() throws {
      let yaml = "{a: 1"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .missingClosingBrace
      )
    }

    @Test
    func `Throws For Missing Closing Bracket`() throws {
      let yaml = "[1, 2"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [Int](),
        reason: .missingClosingBracket
      )
    }

    @Test
    func `Throws For Leading Zero`() throws {
      let yaml = "{a: 01}"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .leadingZero
      )
    }
  }

  @Suite
  struct `YAMLBlockError tests` {
    @Test
    func `Throws For Missing Colon In Block Mapping`() throws {
      let yaml = "value 1"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .missingColon
      )
    }

    @Test
    func `Throws For Missing Value In Block Mapping`() throws {
      let yaml = "value:"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .missingValue
      )
    }

    @Test
    func `Throws For Missing Nested Value In Block Mapping`() throws {
      let yaml = """
      root:
        child:
      """
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: [String: Int]](),
        reason: .missingValue
      )
    }

    @Test
    func `Throws For Unexpected Token In Block Context`() throws {
      let yaml = "]"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [Int](),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Invalid Number In Block Mapping`() throws {
      let yaml = "value: -x"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Invalid Exponent In Block Mapping`() throws {
      let yaml = "value: 1e+"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Double](),
        reason: .invalidExponent
      )
    }

    @Test
    func `Throws For Leading Zero In Block Mapping`() throws {
      let yaml = "value: 01"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .leadingZero
      )
    }

    @Test
    func `Throws For Leading Zero In Block Sequence`() throws {
      let yaml = """
      - 01
      """
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [Int](),
        reason: .leadingZero
      )
    }

    @Test
    func `Throws For Block Scalar When Expecting Integer`() throws {
      let yaml = """
      |
        123
      """
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: 0,
        reason: .invalidType
      )
    }

    @Test
    func `Throws For Block Scalar Property When Expecting Integer`() throws {
      let yaml = """
      value: |
        123
      """
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: IntValueContainer.Partial(),
        reason: .invalidType
      )
    }

    @Test
    func `Throws For Block Scalar Element When Expecting Integer`() throws {
      let yaml = """
      - |
          123
      """
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [Int](),
        reason: .invalidType
      )
    }

    @Test
    func `Throws For Invalid Block Scalar Header`() throws {
      let yaml = "value: | nope"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: YAMLStringValueContainer.Partial(),
        reason: .invalidMultiLineString
      )
    }

    @Test
    func `Throws For Missing Block Scalar Content`() throws {
      let yaml = """
      value: |
      next: 1
      """
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: YAMLStringValueContainer.Partial(),
        reason: .invalidMultiLineString
      )
    }

    @Test
    func `Throws For Incomplete True Literal On Finish`() throws {
      let yaml = "tru"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: false,
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Incomplete False Literal On Finish`() throws {
      let yaml = "fal"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: true,
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Incomplete Null Literal On Finish`() throws {
      let yaml = "nul"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: String?.none,
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Unterminated Key On Finish`() throws {
      let yaml = "key\n"
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .missingColon
      )
    }

    @Test
    func `Throws For Unterminated Quoted Key On Finish`() throws {
      let yaml = "\"key\""
      try expectYAMLStreamParsingError(
        yaml,
        initialValue: [String: Int](),
        reason: .missingColon
      )
    }
  }
}

@Suite
struct `YAMLConfiguration tests` {
  @Test
  func `Allows Comments By Default`() throws {
    let yaml = """
    # top level comment
    first: 1 # inline comment
    # between values
    second: 2
    """
    let values = try yaml.utf8.partials(
      initialValue: [String: Int](),
      from: .yaml()
    )
    expectNoDifference(values.last, ["first": 1, "second": 2])
  }
}

private func expectYAMLStreamedValues<T: StreamParseableValue & Equatable>(
  _ yaml: String,
  configuration: YAMLStreamParserConfiguration = YAMLStreamParserConfiguration(),
  initialValue: T,
  expected: [T],
  file: StaticString = #fileID,
  line: UInt = #line
) throws {
  let values = try yaml.utf8.partials(
    initialValue: initialValue,
    from: .yaml(configuration: configuration)
  )
  expectNoDifference(values, expected, fileID: file, line: line)
}

private func expectYAMLFinalValue<T: StreamParseableValue & Equatable>(
  _ yaml: String,
  configuration: YAMLStreamParserConfiguration = YAMLStreamParserConfiguration(),
  initialValue: T,
  expected: T,
  file: StaticString = #fileID,
  line: UInt = #line
) throws {
  let values = try yaml.utf8.partials(
    initialValue: initialValue,
    from: .yaml(configuration: configuration)
  )
  expectNoDifference(values.last, expected, fileID: file, line: line)
}

private func expectYAMLStreamedValuesBeforeError<T: StreamParseableValue & Equatable>(
  _ yaml: String,
  configuration: YAMLStreamParserConfiguration = YAMLStreamParserConfiguration(),
  initialValue: T,
  expected: [T],
  reason: YAMLStreamParsingError.Reason
) {
  var stream = PartialsStream(initialValue: initialValue, from: .yaml(configuration: configuration))
  var partials = [T]()
  let thrownError = #expect(throws: YAMLStreamParsingError.self) {
    for byte in yaml.utf8 {
      partials.append(try stream.next(byte))
    }
    _ = try stream.finish()
  }

  guard let error = thrownError else {
    Issue.record("Expected YAMLStreamParsingError to be captured.")
    return
  }
  expectNoDifference(error.reason, reason)
  expectNoDifference(partials, expected)
}

private func expectYAMLStreamParsingError<T: StreamParseableValue>(
  _ yaml: String,
  configuration: YAMLStreamParserConfiguration = YAMLStreamParserConfiguration(),
  initialValue: T,
  reason: YAMLStreamParsingError.Reason,
  position: YAMLStreamParsingPosition? = nil
) throws {
  let thrownError = #expect(throws: YAMLStreamParsingError.self) {
    _ = try yaml.utf8.partials(
      initialValue: initialValue,
      from: .yaml(configuration: configuration)
    )
  }

  let error = try #require(thrownError)
  expectNoDifference(error.reason, reason)
  if let position {
    expectNoDifference(error.position, position)
  }
}


@StreamParseable
struct YAMLStringValueContainer: Equatable {
  var value: String = ""
}

extension YAMLStringValueContainer.Partial: Equatable {}

@Suite
struct `YAMLKeyDecodingStrategy tests` {
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
    let strategy = YAMLKeyDecodingStrategy.convertFromSnakeCase
    expectNoDifference(strategy.decode(key: input), expected)
  }

  @Test
  func `UseDefault Leaves Keys Unchanged`() throws {
    let strategy = YAMLKeyDecodingStrategy.useDefault
    expectNoDifference(strategy.decode(key: "snake_case"), "snake_case")
  }

  @Test
  func `Custom Applies Transform`() throws {
    let strategy = YAMLKeyDecodingStrategy.custom { "prefix_\($0)" }
    expectNoDifference(strategy.decode(key: "value"), "prefix_value")
  }

  @Test
  func `Streams YAML Object Using ConvertFromSnakeCase`() throws {
    let yaml = "snake_case: 1"
    let configuration = YAMLStreamParserConfiguration(keyDecodingStrategy: .convertFromSnakeCase)
    let values = try yaml.utf8.partials(
      initialValue: [String: Int](),
      from: .yaml(configuration: configuration)
    )
    expectNoDifference(values.last, ["snakeCase": 1])
  }

  @Test
  func `Streams YAML Object Using Custom Key Decoder`() throws {
    let yaml = "value: 1"
    let configuration = YAMLStreamParserConfiguration(
      keyDecodingStrategy: .custom { "prefix_\($0)" }
    )
    let values = try yaml.utf8.partials(
      initialValue: [String: Int](),
      from: .yaml(configuration: configuration)
    )
    expectNoDifference(values.last, ["prefix_value": 1])
  }
}

@Suite
struct `YAMLDump tests` {
  private let url64Kb = Bundle.module.url(forResource: "64KB", withExtension: "yaml")!
  private let url512Kb = Bundle.module.url(forResource: "512KB", withExtension: "yaml")!
  private let urlDeepNested64 = Bundle.module.url(
    forResource: "DeepNested64",
    withExtension: "yaml"
  )!

  @Test
  func `Small YAML Dump Optional`() throws {
    try self.assertSnapshot(of: [ProfileOptional.Partial].self, from: self.url64Kb)
  }

  @Test
  func `Small YAML Dump Parseable`() throws {
    try self.assertSnapshot(of: [ProfileParseable.Partial].self, from: self.url64Kb)
  }

  @Test
  func `Large YAML Dump Optional`() throws {
    try self.assertSnapshot(of: [ProfileOptional.Partial].self, from: self.url512Kb)
  }

  @Test
  func `Large YAML Dump Parseable`() throws {
    try self.assertSnapshot(of: [ProfileParseable.Partial].self, from: self.url512Kb)
  }

  @Test
  func `Large YAML Dump Parseable Chunked 4KB`() throws {
    try self.assertSnapshot(
      of: [ProfileParseable.Partial].self,
      from: self.url512Kb,
      chunkSize: 4 * 1024
    )
  }

  @Test
  func `Large YAML Dump Optional Chunked 4KB`() throws {
    try self.assertSnapshot(
      of: [ProfileOptional.Partial].self,
      from: self.url512Kb,
      chunkSize: 4 * 1024
    )
  }

  @Test
  func `Nested YAML Dump Partial States`() throws {
    try self.assertNestedPartialSnapshot(
      from: self.urlDeepNested64,
      chunkSize: 256 * 1024,
      testName: #function
    )
  }

  private func assertSnapshot<Value: StreamParseableValue & Encodable>(
    of type: Value.Type,
    from url: URL,
    chunkSize: Int? = nil,
    testName: String = #function
  ) throws {
    let data = try Data(contentsOf: url)
    var stream = PartialsStream(initialValue: type.initialParseableValue(), from: .yaml())
    if let chunkSize {
      let bytes = Array(data)
      var offset = bytes.startIndex
      while offset < bytes.endIndex {
        let endIndex = min(offset + chunkSize, bytes.endIndex)
        _ = try stream.next(bytes[offset..<endIndex])
        offset = endIndex
      }
    } else {
      for byte in data {
        _ = try stream.next(byte)
      }
    }
    let final = try stream.finish()
    SnapshotTesting.assertSnapshot(of: final, as: .yaml, testName: testName)
  }

  private func assertNestedPartialSnapshot(
    from url: URL,
    chunkSize: Int,
    testName: String
  ) throws {
    let data = try Data(contentsOf: url)
    var stream = PartialsStream(
      initialValue: DeepNestedRoot.Partial.initialParseableValue(),
      from: .yaml()
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
    SnapshotTesting.assertSnapshot(of: partials, as: .yaml, testName: testName)
  }
}
