import CustomDump
import StreamParsing
import Testing

@Suite
struct `JSONStreamParser tests` {
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
      let expected = [-1, -12, -123]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Zero With Trailing Decimal`() throws {
      let json = "0.0"
      let expected: [Double] = [0]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float Zero With Trailing Decimal`() throws {
      let json = "0.0"
      let expected: [Float] = [0]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Digits`() throws {
      let json = "12.34"
      let expected: [Double] = [1, 12, 12.3, 12.34]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Negative Double Digits`() throws {
      let json = "-12.34"
      let expected: [Double] = [-1, -12, -12.3, -12.34]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Negative Sign Only`() throws {
      let json = "-"
      let expected: [Int] = []
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float Digits`() throws {
      let json = "12.34"
      let expected: [Float] = [1, 12, 12.3, 12.34]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Exponent Digits`() throws {
      let json = "12e3"
      let expected: [Double] = [1, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Negative Exponent Digits`() throws {
      let json = "12e-3"
      let expected: [Double] = [1, 12, 0.012]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Positive Exponent Digits`() throws {
      let json = "12e+3"
      let expected: [Double] = [1, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double Uppercase Exponent Digits`() throws {
      let json = "12E3"
      let expected: [Double] = [1, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float Exponent Digits`() throws {
      let json = "12e3"
      let expected: [Float] = [1, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float Positive Exponent Digits`() throws {
      let json = "12e+3"
      let expected: [Float] = [1, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float Uppercase Exponent Digits`() throws {
      let json = "12E3"
      let expected: [Float] = [1, 12, 12_000]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Double With Trailing Decimal Zero`() throws {
      let json = "11.0"
      let expected: [Double] = [1, 11]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }

    @Test
    func `Streams JSON Float With Trailing Decimal Zero`() throws {
      let json = "11.0"
      let expected: [Float] = [1, 11]
      try expectJSONStreamedValues(
        json,
        initialValue: 0,
        expected: expected
      )
    }
  }

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

private func expectJSONStreamedValues<T: StreamActionReducer & Equatable>(
  _ json: String,
  configuration: JSONStreamParser.Configuration = JSONStreamParser.Configuration(),
  initialValue: T,
  expected: [T],
  file: StaticString = #fileID,
  line: UInt = #line
) throws {
  var stream = PartialsStream(
    initialValue: TrackingReducer(value: initialValue),
    from: .json(configuration: configuration)
  )
  var values = [T]()
  for byte in json.utf8 {
    let previousCount = stream.current.reduceCount
    let partial = try stream.next(byte)
    if partial.reduceCount != previousCount {
      values.append(partial.value)
    }
  }
  expectNoDifference(values, expected, fileID: file, line: line)
}

private struct TrackingReducer<Value: StreamActionReducer>: StreamActionReducer {
  var value: Value
  var reduceCount = 0

  mutating func reduce(action: StreamAction) throws {
    self.reduceCount += 1
    try self.value.reduce(action: action)
  }
}
