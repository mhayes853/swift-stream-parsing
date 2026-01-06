import CustomDump
import StreamParsing
import Testing

@Suite(.disabled("TODO: - Reimplement"))
struct `JSONStreamParser tests` {
  @Suite
  struct `JSONString tests` {
    @Test
    func `Streams JSON String Characters`() throws {
    let json = "\"Blob\""
    let expected = ["", "B", "Bl", "Blo", "Blob", "Blob"]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }

    @Test
    func `Streams JSON Empty String`() throws {
    let json = "\"\""
    let expected = ["", ""]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }

    @Test
    func `Streams JSON String With Escaped Quote`() throws {
    let json = "\"\\\"\""
    let expected = ["", "", "\"", "\""]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }

    @Test
    func `Streams JSON String With Escaped Backslash`() throws {
    let json = "\"\\\\\""
    let expected = ["", "", "\\", "\\"]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
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
        "line\nend"
      ]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }

    @Test
    func `Streams JSON String With Escaped Slash`() throws {
    let json = "\"\\/\""
    let expected = ["", "", "/", "/"]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }

    @Test
    func `Streams JSON String With Escaped Backspace`() throws {
    let json = "\"\\b\""
    let expected = ["", "", "\u{08}", "\u{08}"]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }

    @Test
    func `Streams JSON String With Escaped Form Feed`() throws {
    let json = "\"\\f\""
    let expected = ["", "", "\u{0C}", "\u{0C}"]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }

    @Test
    func `Streams JSON String With Escaped Carriage Return`() throws {
    let json = "\"\\r\""
    let expected = ["", "", "\r", "\r"]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }

    @Test
    func `Streams JSON String With Escaped Tab`() throws {
    let json = "\"\\t\""
    let expected = ["", "", "\t", "\t"]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }

    @Test
    func `Streams JSON String With Emoji`() throws {
    let json = "\"😀\""
    let expected = ["", "", "", "", "😀", "😀"]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }

    @Test
    func `Streams JSON String With Multiple Emojis`() throws {
    let json = "\"😀😃\""
    let expected = ["", "", "", "", "", "😀", "😀", "😀", "😀😃", "😀😃"]
      try expectJSONStreamedValues(
        json,
        initialValue: "",
        expected: expected
      )
    }
  }

  @Suite
  struct `JSONNumber tests` {
    @Test
    func `Streams JSON Integer Digits`() throws {
      let json = "1234"
      let expected = [1, 12, 123, 1234]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Zero Integer`() throws {
      let json = "0"
      let expected = [0]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Negative Integer Digits`() throws {
    let json = "-123"
    let expected = [0, -1, -12, -123]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Zero With Trailing Decimal`() throws {
    let json = "0.0"
    let expected: [Double] = [0, 0, 0]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float Zero With Trailing Decimal`() throws {
    let json = "0.0"
    let expected: [Float] = [0, 0, 0]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Digits`() throws {
    let json = "12.34"
    let expected: [Double] = [1, 12, 12, 12.3, 12.34]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Negative Double Digits`() throws {
    let json = "-12.34"
    let expected: [Double] = [0, -1, -12, -12, -12.3, -12.34]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Negative Sign Only`() throws {
    let json = "-"
    let expected: [Int] = [0]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float Digits`() throws {
    let json = "12.34"
    let expected: [Float] = [1, 12, 12, 12.3, 12.34]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Exponent Digits`() throws {
    let json = "12e3"
    let expected: [Double] = [1, 12, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Negative Exponent Digits`() throws {
    let json = "12e-3"
    let expected: [Double] = [1, 12, 12, 12, 0.012]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Positive Exponent Digits`() throws {
    let json = "12e+3"
    let expected: [Double] = [1, 12, 12, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Uppercase Exponent Digits`() throws {
    let json = "12E3"
    let expected: [Double] = [1, 12, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float Exponent Digits`() throws {
    let json = "12e3"
    let expected: [Float] = [1, 12, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float Positive Exponent Digits`() throws {
    let json = "12e+3"
    let expected: [Float] = [1, 12, 12, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float Uppercase Exponent Digits`() throws {
    let json = "12E3"
    let expected: [Float] = [1, 12, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double With Trailing Decimal Zero`() throws {
    let json = "11.0"
    let expected: [Double] = [1, 11, 11, 11]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float With Trailing Decimal Zero`() throws {
    let json = "11.0"
    let expected: [Float] = [1, 11, 11, 11]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
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
        18_446_744_073_709_551_615
      ]
      try expectJSONStreamedValues(
        json,
        initialValue: UInt64(0),
        expected: expected
      )
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
        -9_223_372_036_854_775_807
      ]
      try expectJSONStreamedValues(
        json,
        initialValue: Int64(0),
        expected: expected
      )
    }
  }

  @Suite
  struct `JSONBoolean tests` {
    @Test
    func `Streams JSON True`() throws {
    let json = "true"
    let expected = [true, true, true, true]
      try expectJSONStreamedValues(
        json,
        initialValue: false,
        expected: expected
      )
    }

    @Test
    func `Streams JSON False`() throws {
    let json = "false"
    let expected = [false, false, false, false, false]
      try expectJSONStreamedValues(
        json,
        initialValue: true,
        expected: expected
      )
    }

    @Test
    func `Streams JSON True From T`() throws {
      try expectJSONStreamedValues(
        "t",
        initialValue: false,
        expected: [true]
      )
    }

    @Test
    func `Streams JSON False From F`() throws {
      try expectJSONStreamedValues(
        "f",
        initialValue: true,
        expected: [false]
      )
    }
  }

  @Suite
  struct `JSONNull tests` {
    @Test
    func `Streams JSON Null`() throws {
    let json = "null"
    let expected: [String?] = [nil, nil, nil, nil]
      try expectJSONStreamedValues(
        json,
        initialValue: "seed",
        expected: expected
      )
    }

    @Test
    func `Streams JSON Null From N`() throws {
      let expected: [String?] = [nil]
      try expectJSONStreamedValues(
        "n",
        initialValue: "seed",
        expected: expected
      )
    }
  }
}

private func expectJSONStreamedValues<T: StreamParseableValue & Equatable>(
  _ json: String,
  configuration: JSONStreamParser<T>.Configuration = JSONStreamParser<T>.Configuration(),
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
