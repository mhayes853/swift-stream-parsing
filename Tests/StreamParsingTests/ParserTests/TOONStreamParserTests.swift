import CustomDump
import Foundation
import SnapshotTesting
import StreamParsing
import Testing
import ToonFormat

extension Snapshotting where Value: Encodable, Format == String {
  static var toon: SnapshotTesting.Snapshotting<Value, String> {
    Snapshotting(
      pathExtension: "toon",
      diffing: .lines,
      snapshot: { value in
        let encoder = TOONEncoder()
        encoder.limits = .unlimited
        let data = try! encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
      }
    )
  }
}

@Suite
struct `TOONStreamParser tests` {
  @Suite
  struct `TOONString tests` {
    @Test
    func `Streams TOON String Characters`() throws {
      let toon = "\"Blob\""
      let expected = ["", "B", "Bl", "Blo", "Blob", "Blob", "Blob"]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON Empty String`() throws {
      let toon = "\"\""
      let expected = ["", "", ""]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Escaped Quote`() throws {
      let toon = "\"\\\"\""
      let expected = ["", "", "\"", "\"", "\""]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Escaped Backslash`() throws {
      let toon = "\"\\\\\""
      let expected = ["", "", "\\", "\\", "\\"]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Escaped Newline`() throws {
      let toon = "\"line\\nend\""
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
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Escaped Carriage Return`() throws {
      let toon = "\"\\r\""
      let expected = ["", "", "\r", "\r", "\r"]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Escaped Tab`() throws {
      let toon = "\"\\t\""
      let expected = ["", "", "\t", "\t", "\t"]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Emoji`() throws {
      let toon = "\"😀\""
      let expected = ["", "", "", "", "😀", "😀", "😀"]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Multiple Emojis`() throws {
      let toon = "\"😀😃\""
      let expected = ["", "", "", "", "😀", "😀", "😀", "😀", "😀😃", "😀😃", "😀😃"]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Two-Byte Character`() throws {
      let toon = "\"\u{00E9}\""
      let expected = ["", "", "\u{00E9}", "\u{00E9}", "\u{00E9}"]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Four-Byte NonEmoji Character`() throws {
      let toon = "\"\u{1D11E}\""
      let expected = ["", "", "", "", "\u{1D11E}", "\u{1D11E}", "\u{1D11E}"]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Square Brackets Inside`() throws {
      let toon = "\"[]\""
      let expected = ["", "[", "[]", "[]", "[]"]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String With Consecutive Four-Byte Scalars`() throws {
      let scalar1 = "\u{10437}"
      let scalar2 = "\u{10438}"
      let toon = "\"\(scalar1)\(scalar2)\""
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
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Streams TOON String Containing Only Numbers`() throws {
      let toon = "\"123\""
      let expected = ["", "1", "12", "123", "123", "123"]
      try expectTOONStreamedValues(toon, initialValue: "", expected: expected)
    }

    @Test
    func `Chunked Parsing Flushes TOON String Once Per Chunk`() throws {
      var stream = PartialsStream(
        initialValue: StringValueContainer.Partial(),
        from: .toon()
      )

      let first = try stream.next("value: \"Bl".utf8)
      let second = try stream.next("ob\"".utf8)
      let final = try stream.finish()

      expectNoDifference(first, StringValueContainer.Partial(value: "Bl"))
      expectNoDifference(second, StringValueContainer.Partial(value: "Blob"))
      expectNoDifference(final, StringValueContainer.Partial(value: "Blob"))
    }

  }

  @Suite
  struct `TOONNumber tests` {
    @Test
    func `Streams TOON Integer Digits`() throws {
      let toon = "1234"
      let expected = [1, 12, 123, 1234, 1234]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Zero Integer`() throws {
      let toon = "0"
      let expected = [0, 0]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Negative Integer Digits`() throws {
      let toon = "-123"
      let expected = [0, -1, -12, -123, -123]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Double Digits`() throws {
      let toon = "12.34"
      let expected: [Double] = [1, 12, 12, 12.3, 12.34, 12.34]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Double Zero With Trailing Decimal`() throws {
      let toon = "0.0"
      let expected: [Double] = [0, 0, 0, 0]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Float Zero With Trailing Decimal`() throws {
      let toon = "0.0"
      let expected: [Float] = [0, 0, 0, 0]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Negative Double Digits`() throws {
      let toon = "-12.34"
      let expected: [Double] = [0, -1, -12, -12, -12.3, -12.34, -12.34]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Float Digits`() throws {
      let toon = "12.34"
      let expected: [Float] = [1, 12, 12, 12.3, 12.34, 12.34]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Exponent Digits`() throws {
      let toon = "12e3"
      let expected: [Double] = [1, 12, 12, 12_000, 12_000]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Negative Exponent Digits`() throws {
      let toon = "12e-3"
      let expected: [Double] = [1, 12, 12, 12, 12, 0.012]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Positive Exponent Digits`() throws {
      let toon = "12e+3"
      let expected: [Double] = [1, 12, 12, 12, 12, 12_000]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Uppercase Exponent Digits`() throws {
      let toon = "12E3"
      let expected: [Double] = [1, 12, 12, 12_000, 12_000]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Double Large Positive Exponent Digits`() throws {
      let toon = "12e21"
      let expected = 1.2e22
      let values = try toon.utf8.partials(initialValue: 0.0, from: .toon())
      expectNoDifference(values.count, toon.utf8.count + 1)
      expectClose(try #require(values.last), expected, epsilon: 1e7)
    }

    @Test
    func `Streams TOON Double Large Negative Exponent Digits`() throws {
      let toon = "12e-21"
      let expected = 1.2e-20
      let values = try toon.utf8.partials(initialValue: 0.0, from: .toon())
      expectNoDifference(values.count, toon.utf8.count + 1)
      expectClose(try #require(values.last), expected, epsilon: 1e-30)
    }

    @Test
    func `Streams TOON Double Positive Zero Exponent Digits`() throws {
      let toon = "12e+0"
      let expected: [Double] = [1, 12, 12, 12, 12, 12]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Double Negative Zero Exponent Digits`() throws {
      let toon = "12e-0"
      let expected: [Double] = [1, 12, 12, 12, 12, 12]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Float Exponent Digits`() throws {
      let toon = "12e3"
      let expected: [Float] = [1, 12, 12, 12_000, 12_000]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Float Positive Exponent Digits`() throws {
      let toon = "12e+3"
      let expected: [Float] = [1, 12, 12, 12, 12, 12_000]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Float Uppercase Exponent Digits`() throws {
      let toon = "12E3"
      let expected: [Float] = [1, 12, 12, 12_000, 12_000]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Double With Trailing Decimal Zero`() throws {
      let toon = "11.0"
      let expected: [Double] = [1, 11, 11, 11, 11]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Float With Trailing Decimal Zero`() throws {
      let toon = "11.0"
      let expected: [Float] = [1, 11, 11, 11, 11]
      try expectTOONStreamedValues(toon, initialValue: 0, expected: expected)
    }

    @Test
    func `Streams TOON Large Integer Digits`() throws {
      let toon = "18446744073709551615"
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
      try expectTOONStreamedValues(toon, initialValue: UInt64(0), expected: expected)
    }

    @Test
    func `Streams TOON Large Negative Integer Digits`() throws {
      let toon = "-9223372036854775807"
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
      try expectTOONStreamedValues(toon, initialValue: Int64(0), expected: expected)
    }

    @Test
    @available(StreamParsing128BitIntegers, *)
    func `Streams TOON Large UInt128 Digits`() throws {
      let toon = "340282366920938463463374607431768211455"
      let values = try toon.utf8.partials(initialValue: UInt128(0), from: .toon())
      expectNoDifference(values.count, toon.utf8.count + 1)
      expectNoDifference(try #require(values.last), UInt128.max)
    }

    @Test
    @available(StreamParsing128BitIntegers, *)
    func `Streams TOON Large Negative Int128 Digits`() throws {
      let toon = "-170141183460469231731687303715884105727"
      let values = try toon.utf8.partials(initialValue: Int128(0), from: .toon())
      expectNoDifference(values.count, toon.utf8.count + 1)
      expectNoDifference(try #require(values.last), Int128.min + 1)
    }

    @Test
    func `Chunked Parsing Flushes TOON Number Once Per Chunk`() throws {
      var stream = PartialsStream(
        initialValue: IntValueContainer.Partial(),
        from: .toon()
      )

      let first = try stream.next("value: 12".utf8)
      let second = try stream.next("34".utf8)
      let final = try stream.finish()

      expectNoDifference(first, IntValueContainer.Partial(value: 12))
      expectNoDifference(second, IntValueContainer.Partial(value: 1_234))
      expectNoDifference(final, IntValueContainer.Partial(value: 1_234))
    }

    @Test
    func `Treats Leading Zero Number-Like Token As String`() throws {
      let toon = "value: 05"
      try expectTOONFinalValue(
        toon,
        initialValue: TOONStringValueContainer.Partial(),
        expected: TOONStringValueContainer.Partial(value: "05")
      )
    }
  }

  @Suite
  struct `TOONLiteral tests` {
    @Test
    func `Streams TOON True Literal`() throws {
      let toon = "true"
      let expected = [false, false, false, true, true]
      try expectTOONStreamedValues(toon, initialValue: false, expected: expected)
    }

    @Test
    func `Streams TOON False Literal`() throws {
      let toon = "false"
      let expected = [true, true, true, true, false, false]
      try expectTOONStreamedValues(toon, initialValue: true, expected: expected)
    }

    @Test
    func `Streams TOON Null Literal Into Optional`() throws {
      let toon = "null"
      let expected: [Int?] = [0, 0, 0, nil, nil]
      try expectTOONStreamedValues(toon, initialValue: Int?.initialParseableValue(), expected: expected)
    }

    @Test
    func `Keeps Quoted Literal-Looking Token As String`() throws {
      let toon = "value: \"true\""
      try expectTOONFinalValue(
        toon,
        initialValue: TOONStringValueContainer.Partial(),
        expected: TOONStringValueContainer.Partial(value: "true")
      )
    }
  }

  @Suite
  struct `TOONArray tests` {
    @Test
    func `Streams TOON Inline Primitive Array`() throws {
      let toon = "[3]: 1,2,3"
      try expectTOONFinalValue(toon, initialValue: [Int](), expected: [1, 2, 3])
    }

    @Test(arguments: [
      ("\"a:b\"", "a:b"),
      ("\"a,b\"", "a,b"),
      ("\"[a]\"", "[a]"),
      ("\"{a:b}\"", "{a:b}")
    ])
    func `Streams TOON Block String Array Item With Delimiters Inside Quotes`(
      element: String,
      expectedElement: String
    ) throws {
      let toon = """
      [1]:
        - \(element)
      """
      try expectTOONFinalValue(toon, initialValue: [String](), expected: [expectedElement])
    }

    @Test
    func `Streams TOON Array With Fractional And Exponential Double`() throws {
      let toon = "[3]: 1.5,2e2,-3.25"
      try expectTOONFinalValue(toon, initialValue: [Double](), expected: [1.5, 200, -3.25])
    }

    @Test
    func `Streams TOON String Array`() throws {
      let toon = "[3]: Ada,Blob,Scout"
      try expectTOONFinalValue(toon, initialValue: [String](), expected: ["Ada", "Blob", "Scout"])
    }

    @Test
    func `Streams TOON Boolean Array`() throws {
      let toon = "[2]: true,false"
      try expectTOONFinalValue(toon, initialValue: [Bool](), expected: [true, false])
    }

    @Test
    func `Streams TOON Optional Array`() throws {
      let toon = "[3]: 1,null,3"
      try expectTOONFinalValue(toon, initialValue: [Int?](), expected: [1, nil, 3])
    }

    @Test
    func `Streams TOON Integer 2D Array`() throws {
      let toon = """
      [2]:
        - [2]: 1,2
        - [2]: 3,4
      """
      try expectTOONFinalValue(toon, initialValue: [[Int]](), expected: [[1, 2], [3, 4]])
    }

    @Test
    func `Streams TOON String 2D Array`() throws {
      let toon = """
      [2]:
        - [2]: Ada,Blob
        - [2]: Scout,Taylor
      """
      try expectTOONFinalValue(
        toon,
        initialValue: [[String]](),
        expected: [["Ada", "Blob"], ["Scout", "Taylor"]]
      )
    }

    @Test
    func `Streams TOON Boolean 2D Array`() throws {
      let toon = """
      [2]:
        - [2]: true,false
        - [2]: false,true
      """
      try expectTOONFinalValue(toon, initialValue: [[Bool]](), expected: [[true, false], [false, true]])
    }

    @Test
    func `Streams TOON Optional 2D Array`() throws {
      let toon = """
      [2]:
        - [2]: 1,null
        - [2]: null,4
      """
      try expectTOONFinalValue(toon, initialValue: [[Int?]](), expected: [[1, nil], [nil, 4]])
    }

    @Test
    func `Streams TOON Integer 3D Array Single Element`() throws {
      let toon = """
      [1]:
        - [1]:
          - [1]: 1
      """
      try expectTOONFinalValue(toon, initialValue: [[[Int]]](), expected: [[[1]]])
    }

    @Test
    func `Streams TOON Mixed Object And Array Parsing`() throws {
      let toon = """
      user:
        id: 1
        name: Ada
      tags[2]: swift,toon
      """
      let expected = TOONSnapshotRoot.Partial(
        user: TOONUser.Partial(id: 1, name: "Ada"),
        tags: ["swift", "toon"]
      )
      try expectTOONFinalValue(toon, initialValue: TOONSnapshotRoot.Partial(), expected: expected)
    }

    @Test
    func `Streams TOON Tabular Array`() throws {
      let toon = """
      [2]{id,name}:
        1,Ada
        2,Bob
      """
      let expected = [
        TOONUser.Partial(id: 1, name: "Ada"),
        TOONUser.Partial(id: 2, name: "Bob")
      ]
      try expectTOONFinalValue(toon, initialValue: [TOONUser.Partial](), expected: expected)
    }

    @Test
    func `Streams TOON Pipe Delimited Tabular Array`() throws {
      let toon = """
      [2|]{id|name}:
        1|Ada
        2|Bob Smith
      """
      let expected = [
        TOONUser.Partial(id: 1, name: "Ada"),
        TOONUser.Partial(id: 2, name: "Bob Smith")
      ]
      try expectTOONFinalValue(toon, initialValue: [TOONUser.Partial](), expected: expected)
    }
  }

  @Suite
  struct `TOONObject tests` {
    @Test
    func `Streams TOON Empty Object Into Dictionary`() throws {
      try expectTOONStreamedValues("", initialValue: [String: Int](), expected: [[:]])
    }

    @Test
    func `Streams TOON Object With Single Key Into Dictionary`() throws {
      let toon = "first: 1"
      let expected = Array(repeating: [String: Int](), count: 7)
        + [["first": 1], ["first": 1]]
      try expectTOONStreamedValues(toon, initialValue: [String: Int](), expected: expected)
    }

    @Test
    func `Streams TOON Object With Two Keys Into Dictionary`() throws {
      let toon = """
      first: 1
      second: 2
      """
      let initial = Array(repeating: [String: Int](), count: 7)
      let firstPhase = Array(repeating: ["first": 1], count: 10)
      let finalPhase = [["first": 1, "second": 2], ["first": 1, "second": 2]]
      try expectTOONStreamedValues(toon, initialValue: [String: Int](), expected: initial + firstPhase + finalPhase)
    }

    @Test
    func `Streams TOON Object With Two Keys Into StreamParseable Struct`() throws {
      let toon = """
      first: 1
      second: 2
      """
      let expected = TwoKeyObject.Partial(first: 1, second: 2)
      let initial = Array(repeating: TwoKeyObject.Partial(), count: 7)
      let firstPhase = Array(repeating: TwoKeyObject.Partial(first: 1), count: 10)
      let finalPhase = [expected, expected]
      try expectTOONStreamedValues(toon, initialValue: TwoKeyObject.Partial(), expected: initial + firstPhase + finalPhase)
    }

    @Test
    func `Continues Parsing TOON After Ignored Key`() throws {
      let toon = """
      ignored: 1
      tracked: Blob
      """
      try expectTOONFinalValue(
        toon,
        initialValue: TrackedOnly.Partial(),
        expected: TrackedOnly.Partial(tracked: "Blob")
      )
    }

    @Test
    func `Streams TOON Nested Object`() throws {
      let toon = """
      user:
        id: 1
        name: Ada
      """
      let expected = TOONRootObject.Partial(user: TOONUser.Partial(id: 1, name: "Ada"))
      try expectTOONFinalValue(toon, initialValue: TOONRootObject.Partial(), expected: expected)
    }

    @Test
    func `Streams TOON Nested Object Into Dictionary Of Dictionaries`() throws {
      let toon = """
      user:
        id: 1
      """
      let expected = ["user": ["id": 1]]
      try expectTOONFinalValue(toon, initialValue: [String: [String: Int]](), expected: expected)
    }

    @Test
    func `Streams TOON Nested Object Into StreamParseable Struct`() throws {
      let toon = """
      nested:
        value: 1
      """
      let expected = NestedContainer.Partial(nested: NestedValue.Partial(value: 1))
      try expectTOONFinalValue(toon, initialValue: NestedContainer.Partial(), expected: expected)
    }

    @Test
    func `Streams TOON Object With Nullable Value Into StreamParseable Struct`() throws {
      let toon = "maybe: null"
      let values = try toon.utf8.partials(
        initialValue: NullableObject.Partial(),
        from: .toon()
      )
      expectNoDifference(values.count, toon.utf8.count + 1)
      expectNoDifference(try #require(values.last).maybe, .some(nil))
    }

    @Test
    func `Streams TOON Object With Nested Nullable Value Into StreamParseable Struct`() throws {
      let toon = """
      inner:
        maybe: null
      """
      try expectTOONFinalValue(
        toon,
        initialValue: NullableNestedContainer.Partial(),
        expected: NullableNestedContainer.Partial(
          inner: NullableNestedValue.Partial(maybe: .some(nil))
        )
      )
    }

    @Test
    func `Streams TOON Object With Nullable Value Into Dictionary`() throws {
      let toon = "maybe: null"
      try expectTOONFinalValue(toon, initialValue: [String: Int?](), expected: ["maybe": nil])
    }

    @Test
    func `Parses Empty TOON Object From Boolean Property`() throws {
      try expectTOONFinalValue("value:", initialValue: BoolValueContainer.Partial(), expected: BoolValueContainer.Partial())
    }

    @Test
    func `Parses Empty TOON Object From Null Property`() throws {
      try expectTOONFinalValue("maybe:", initialValue: NullableObject.Partial(), expected: NullableObject.Partial())
    }

    @Test
    func `Parses Empty TOON Object From Array Property`() throws {
      try expectTOONFinalValue("numbers:", initialValue: ArrayPropertyContainer.Partial(), expected: ArrayPropertyContainer.Partial())
    }

    @Test
    func `Streams TOON Object With Dictionary Property Into StreamParseable Struct`() throws {
      let toon = """
      values:
        first: 1
        second: 2
      """
      let expected = DictionaryPropertyContainer.Partial(values: ["first": 1, "second": 2])
      try expectTOONFinalValue(toon, initialValue: DictionaryPropertyContainer.Partial(), expected: expected)
    }

    @Test
    func `Streams TOON Object With Array Property Into StreamParseable Struct`() throws {
      let toon = "numbers[3]: 1,2,3"
      let expected = ArrayPropertyContainer.Partial(numbers: [1, 2, 3])
      try expectTOONFinalValue(toon, initialValue: ArrayPropertyContainer.Partial(), expected: expected)
    }

    @Test
    func `Streams TOON Object With Nested Array Property Into StreamParseable Struct`() throws {
      let toon = """
      level1:
        level2:
          numbers[3]: 1,2,3
      """
      let expected = ArrayNestedRoot.Partial(
        level1: ArrayNestedLevel1.Partial(level2: ArrayNestedLevel2.Partial(numbers: [1, 2, 3]))
      )
      try expectTOONFinalValue(toon, initialValue: ArrayNestedRoot.Partial(), expected: expected)
    }

    @Test
    func `Parses TOON Object Into Empty StreamParseable Type`() throws {
      let toon = "value: 1"
      let expected = Array(repeating: EmptyObject.Partial(), count: toon.utf8.count + 1)
      try expectTOONStreamedValues(toon, initialValue: EmptyObject.Partial(), expected: expected)
    }

    @Test
    func `Streams TOON Empty Object Into StreamParseable Struct`() throws {
      try expectTOONStreamedValues("", initialValue: EmptyObject.Partial(), expected: [EmptyObject.Partial()])
    }

    @Test
    func `Streams TOON Object With Duplicate Keys Into Dictionary Keeping Last Value`() throws {
      let toon = """
      value: 1
      value: 2
      """
      let initial = Array(repeating: [String: Int](), count: 7)
      let firstValue = Array(repeating: ["value": 1], count: 9)
      let overwritten = [["value": 2], ["value": 2]]
      try expectTOONStreamedValues(toon, initialValue: [String: Int](), expected: initial + firstValue + overwritten)
    }

    @Test
    func `Streams TOON Dotted Keys Literally By Default`() throws {
      let toon = "user.name: Ada"
      let values = try toon.utf8.partials(
        initialValue: [String: String](),
        from: .toon()
      )
      expectNoDifference(values.count, toon.utf8.count + 1)
      expectNoDifference(values.last, ["user.name": "Ada"])
    }

    @Test
    func `Streams TOON Dotted Keys With Safe Path Expansion`() throws {
      let toon = "user.name: Ada"
      let configuration = TOONStreamParserConfiguration(pathExpansionStrategy: .expandSafe)
      let values = try toon.utf8.partials(
        initialValue: TOONRootObject.Partial(),
        from: .toon(configuration: configuration)
      )
      let expected = TOONRootObject.Partial(user: TOONUser.Partial(id: nil, name: "Ada"))
      expectNoDifference(values.count, toon.utf8.count + 1)
      expectNoDifference(values.last, expected)
    }
  }

  @Suite
  struct `TOONError tests` {
    @Test
    func `Streams TOON Values Before Syntax Error`() {
      let toon = """
      first: 1
      second: -
      """
      var stream = PartialsStream(initialValue: [String: Int](), from: .toon())
      var partials = [[String: Int]]()
      let thrownError = #expect(throws: TOONStreamParsingError.self) {
        for byte in toon.utf8 {
          partials.append(try stream.next(byte))
        }
        _ = try stream.finish()
      }

      expectNoDifference(thrownError?.reason, .invalidNumber)
      expectNoDifference(partials.last, ["first": 1])
    }

    @Test
    func `Throws For Missing Colon`() throws {
      try expectTOONParsingError(
        "value 1",
        initialValue: [String: Int](),
        reason: .missingColon
      )
    }

    @Test
    func `Throws For Missing Value`() throws {
      try expectTOONParsingError(
        "value:",
        initialValue: [String: Int](),
        reason: .missingValue
      )
    }

    @Test
    func `Throws For Missing Nested Value`() throws {
      let toon = """
      root:
        child:
      """
      try expectTOONParsingError(
        toon,
        initialValue: [String: [String: Int]](),
        reason: .missingValue
      )
    }

    @Test
    func `Throws For Unterminated String`() throws {
      try expectTOONParsingError(
        "\"unterminated",
        initialValue: "",
        reason: .unterminatedString
      )
    }

    @Test
    func `Throws For Invalid Escape`() throws {
      try expectTOONParsingError(
        "\"\\b\"",
        initialValue: "",
        reason: .invalidEscape
      )
    }

    @Test
    func `Throws For Trailing Junk After Quoted String Value`() throws {
      try expectTOONParsingError(
        "value: \"ok\"junk",
        initialValue: [String: String](),
        reason: .unexpectedToken
      )
    }

    @Test
    func `Throws For Invalid Literal`() throws {
      try expectTOONParsingError(
        "value: tru",
        initialValue: [String: Bool](),
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Incomplete False Literal On Finish`() throws {
      try expectTOONParsingError(
        "fal",
        initialValue: true,
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Incomplete Null Literal On Finish`() throws {
      try expectTOONParsingError(
        "nul",
        initialValue: Int?.none,
        reason: .invalidLiteral
      )
    }

    @Test
    func `Throws For Invalid Number`() throws {
      try expectTOONParsingError(
        "value: -",
        initialValue: [String: Int](),
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Invalid Fractional Number`() throws {
      try expectTOONParsingError(
        "1.",
        initialValue: 0.0,
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Invalid Exponent`() throws {
      try expectTOONParsingError(
        "1e+",
        initialValue: 0.0,
        reason: .invalidNumber
      )
    }

    @Test
    func `Throws For Numeric Overflow`() throws {
      try expectTOONParsingError(
        "18446744073709551616",
        initialValue: UInt64(),
        reason: .numericOverflow
      )
    }

    @Test
    func `Throws On Declared Array Length Mismatch`() throws {
      try expectTOONParsingError(
        "[2]: 1",
        initialValue: [Int](),
        reason: .arrayLengthMismatch
      )
    }

    @Test
    func `Throws On Tabular Width Mismatch`() throws {
      let toon = """
      items[1]{id,name}:
        1
      """
      try expectTOONParsingError(
        toon,
        initialValue: [TOONUser.Partial](),
        reason: .tabularWidthMismatch
      )
    }

    @Test
    func `Throws For Invalid Array Header`() throws {
      try expectTOONParsingError(
        "[x]: 1",
        initialValue: [Int](),
        reason: .invalidArrayHeader
      )
    }

    @Test
    func `Throws For Invalid Array Item`() throws {
      let toon = """
      [1]:
        1
      """
      try expectTOONParsingError(
        toon,
        initialValue: [Int](),
        reason: .invalidArrayItem
      )
    }

    @Test
    func `Throws For Invalid Indentation`() throws {
      let toon = """
      root:
         value: 1
      """
      try expectTOONParsingError(
        toon,
        initialValue: [String: [String: Int]](),
        reason: .invalidIndentation
      )
    }

    @Test
    func `Throws For String When Expecting Integer`() throws {
      try expectTOONParsingError(
        "\"123\"",
        initialValue: 0,
        reason: .invalidType
      )
    }

    @Test
    func `Throws For String Property When Expecting Integer In Object`() throws {
      try expectTOONParsingError(
        "value: \"123\"",
        initialValue: IntValueContainer.Partial(),
        reason: .invalidType
      )
    }

    @Test
    func `Throws For String Element When Expecting Integer In Array`() throws {
      try expectTOONParsingError(
        "[1]: \"123\"",
        initialValue: [Int](),
        reason: .invalidType
      )
    }

    @Test
    func `Throws For Integer When Expecting Boolean`() throws {
      try expectTOONParsingError(
        "1",
        initialValue: false,
        reason: .invalidType
      )
    }

    @Test
    func `Throws For Integer Property When Expecting Boolean In Object`() throws {
      try expectTOONParsingError(
        "value: 1",
        initialValue: BoolValueContainer.Partial(),
        reason: .invalidType
      )
    }

    @Test
    func `Throws For Integer Element When Expecting Boolean In Array`() throws {
      try expectTOONParsingError(
        "[1]: 1",
        initialValue: [Bool](),
        reason: .invalidType
      )
    }

    @Test
    func `Throws For Null When Expecting Integer`() throws {
      try expectTOONParsingError(
        "null",
        initialValue: 0,
        reason: .invalidType
      )
    }

    @Test
    func `Throws For Null Element When Expecting Integer In Array`() throws {
      try expectTOONParsingError(
        "[1]: null",
        initialValue: [Int](),
        reason: .invalidType
      )
    }
  }

}

@Suite
struct `TOONDump tests` {
  private let url64Kb = Bundle.module.url(forResource: "64KB", withExtension: "toon")!
  private let url512Kb = Bundle.module.url(forResource: "512KB", withExtension: "toon")!
  private let urlDeepNested64 = Bundle.module.url(
    forResource: "DeepNested64",
    withExtension: "toon"
  )!

  @Test
  func `Small TOON Dump Optional`() throws {
    try self.assertSnapshot(of: [ProfileOptional.Partial].self, from: self.url64Kb)
  }

  @Test
  func `Small TOON Dump Parseable`() throws {
    try self.assertSnapshot(of: [ProfileParseable.Partial].self, from: self.url64Kb)
  }

  @Test
  func `Large TOON Dump Optional`() throws {
    try self.assertSnapshot(of: [ProfileOptional.Partial].self, from: self.url512Kb)
  }

  @Test
  func `Large TOON Dump Parseable`() throws {
    try self.assertSnapshot(of: [ProfileParseable.Partial].self, from: self.url512Kb)
  }

  @Test
  func `Large TOON Dump Parseable Chunked 4KB`() throws {
    try self.assertSnapshot(
      of: [ProfileParseable.Partial].self,
      from: self.url512Kb,
      chunkSize: 4 * 1024
    )
  }

  @Test
  func `Large TOON Dump Optional Chunked 4KB`() throws {
    try self.assertSnapshot(
      of: [ProfileOptional.Partial].self,
      from: self.url512Kb,
      chunkSize: 4 * 1024
    )
  }

  @Test
  func `Nested TOON Dump Partial States`() throws {
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
    var stream = PartialsStream(initialValue: type.initialParseableValue(), from: .toon())
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
    let snapshot = try self.serializedTOON(final)
    let expected = try self.expectedSnapshot(named: testName)
    expectNoDifference(snapshot, expected)
  }

  private func assertNestedPartialSnapshot(
    from url: URL,
    chunkSize: Int,
    testName: String
  ) throws {
    let data = try Data(contentsOf: url)
    var stream = PartialsStream(
      initialValue: DeepNestedRoot.Partial.initialParseableValue(),
      from: .toon()
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
    let snapshot = try self.serializedTOON(partials)
    let expected = try self.expectedSnapshot(named: testName)
    expectNoDifference(snapshot, expected)
  }

  private func serializedTOON<Value: Encodable>(_ value: Value) throws -> String {
    let encoder = TOONEncoder()
    encoder.limits = .unlimited
    let data = try encoder.encode(value)
    return String(decoding: data, as: UTF8.self)
  }

  private func expectedSnapshot(named testName: String) throws -> String {
    let fileURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appendingPathComponent("__Snapshots__", isDirectory: true)
      .appendingPathComponent("TOONStreamParserTests", isDirectory: true)
      .appendingPathComponent("\(self.snapshotFileName(for: testName)).1.toon")
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

  private func snapshotFileName(for testName: String) -> String {
    testName
      .replacingOccurrences(of: "()", with: "")
      .replacingOccurrences(of: " ", with: "-")
  }
}

private func expectTOONStreamedValues<T: StreamParseableValue & Equatable>(
  _ toon: String,
  configuration: TOONStreamParserConfiguration = TOONStreamParserConfiguration(),
  initialValue: T,
  expected: [T],
  file: StaticString = #fileID,
  line: UInt = #line
) throws {
  let values = try toon.utf8.partials(
    initialValue: initialValue,
    from: .toon(configuration: configuration)
  )
  expectNoDifference(values, expected, fileID: file, line: line)
}

private func expectTOONFinalValue<T: StreamParseableValue & Equatable>(
  _ toon: String,
  configuration: TOONStreamParserConfiguration = TOONStreamParserConfiguration(),
  initialValue: T,
  expected: T,
  file: StaticString = #fileID,
  line: UInt = #line
) throws {
  let values = try toon.utf8.partials(
    initialValue: initialValue,
    from: .toon(configuration: configuration)
  )
  expectNoDifference(values.count, toon.utf8.count + 1, fileID: file, line: line)
  expectNoDifference(values.last, expected, fileID: file, line: line)
}

private func expectTOONStreamedValuesBeforeError<T: StreamParseableValue & Equatable>(
  _ toon: String,
  configuration: TOONStreamParserConfiguration = TOONStreamParserConfiguration(),
  initialValue: T,
  expected: [T],
  reason: TOONStreamParsingError.Reason
) {
  var stream = PartialsStream(initialValue: initialValue, from: .toon(configuration: configuration))
  var partials = [T]()
  let thrownError = #expect(throws: TOONStreamParsingError.self) {
    for byte in toon.utf8 {
      partials.append(try stream.next(byte))
    }
    _ = try stream.finish()
  }

  guard let error = thrownError else {
    Issue.record("Expected TOONStreamParsingError to be captured.")
    return
  }
  expectNoDifference(error.reason, reason)
  expectNoDifference(partials, expected)
}

private func expectTOONParsingError<T: StreamParseableValue>(
  _ toon: String,
  configuration: TOONStreamParserConfiguration = TOONStreamParserConfiguration(),
  initialValue: T,
  reason: TOONStreamParsingError.Reason
) throws {
  let thrownError = #expect(throws: TOONStreamParsingError.self) {
    _ = try toon.utf8.partials(
      initialValue: initialValue,
      from: .toon(configuration: configuration)
    )
  }
  let error = try #require(thrownError)
  expectNoDifference(error.reason, reason)
}

@StreamParseable
struct TOONStringValueContainer: Equatable {
  var value: String = ""
}

@StreamParseable
struct TOONUser: Equatable, Codable {
  var id: Int = 0
  var name: String = ""
}

@StreamParseable
struct TOONRootObject: Equatable {
  var user: TOONUser = TOONUser()
}

@StreamParseable
struct TOONSnapshotRoot: Equatable, Codable {
  var user: TOONUser = TOONUser()
  var tags: [String] = []
}

extension TOONStringValueContainer.Partial: Equatable {}
extension TOONUser.Partial: Equatable, Codable {}
extension TOONRootObject.Partial: Equatable {}
extension TOONSnapshotRoot.Partial: Equatable, Codable {}

extension BoolValueContainer.Partial: Equatable {
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.value == rhs.value
  }
}
