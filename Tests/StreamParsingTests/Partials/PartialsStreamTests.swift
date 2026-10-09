import StreamParsing
import CustomDump
import Testing

@Suite
struct `PartialsStream Tests` {
  @Test
  func `Rejects Next After Parser Throws`() throws {
    var stream = PartialsStream(initialValue: 0, from: .json())

    #expect(throws: JSONParsingError.self) {
      _ = try stream.next(UInt8(ascii: "@"))
    }

    #expect(throws: StreamParsingError.parserFailed) {
      _ = try stream.next(UInt8(ascii: "1"))
    }
  }

  @Test
  func `Finish Throws After Parser Throws`() throws {
    var stream = PartialsStream(initialValue: 0, from: .json())

    #expect(throws: JSONParsingError.self) {
      _ = try stream.next(UInt8(ascii: "@"))
    }

    // Not `#expect(throws:)`: its closure cannot consume the stream it captures.
    do {
      _ = try stream.finish()
      Issue.record("finish() succeeded after the parser threw")
    } catch let error as StreamParsingError {
      expectNoDifference(error, .parserFailed)
    }
  }

  // An incomplete document is only an error at the end, which is the whole point of a streaming
  // parser: every prefix is a legitimate state until the caller says there is no more input.
  @Test
  func `Finish Throws On An Incomplete Document`() throws {
    var stream = PartialsStream(initialValue: StreamArray<Int>(), from: .json())
    for byte in "[1,2".utf8 {
      try stream.next(byte)
    }
    // The trailing 2 is still an open token, so it is not part of any state yet.
    expectNoDifference(stream.current, [1])
    do {
      _ = try stream.finish()
      Issue.record("finish() accepted an incomplete document")
    } catch is JSONParsingError {
    }
  }

  // The sink holds pointers into the value, and the value lives in its own allocation so those
  // survive the stream being moved. Nesting is where a stale pointer would show up.
  @Test
  func `Deeply Nested Values Update Across Bytes`() throws {
    var stream = PartialsStream(initialValue: StreamArray<StreamArray<Int>>(), from: .json())
    for byte in "[[1],[2,3]]".utf8 {
      try stream.next(byte)
    }
    let finished = try stream.finish()
    expectNoDifference(finished, [[1], [2, 3]])
  }

  @Test
  func `Finish Value Moves The Final Value Out`() throws {
    var stream = PartialsStream(initialValue: StreamArray<StreamArray<Int>>(), from: .json())
    for byte in "[[1],[2,3]]".utf8 {
      try stream.next(byte)
    }
    let value = try stream.finishPartial()
    expectNoDifference(value, [[1], [2, 3]])
  }

  @Test
  func `Finish Value Throws On An Incomplete Document`() throws {
    var stream = PartialsStream(initialValue: StreamArray<Int>(), from: .json())
    for byte in "[1,2".utf8 {
      try stream.next(byte)
    }
    do {
      _ = try stream.finishPartial()
      Issue.record("finishPartial accepted an incomplete document")
    } catch is JSONParsingError {
    }
  }

  @Test
  func `Finish Value Resetting Reuses The Stream Across Documents`() throws {
    var stream = PartialsStream(initialValue: StreamArray<StreamArray<Int>>(), from: .json())
    for byte in "[[1],[2,3]]".utf8 {
      try stream.next(byte)
    }
    let first = try stream.finishAndReset(to: StreamArray<StreamArray<Int>>())
    expectNoDifference(first, [[1], [2, 3]])

    // The reused stream starts clean: no leftover containers, buffer bytes, or failure state.
    expectNoDifference(stream.current, [])
    for byte in "[[7,8,9]]".utf8 {
      try stream.next(byte)
    }
    let second = try stream.finishAndReset(to: StreamArray<StreamArray<Int>>())
    expectNoDifference(second, [[7, 8, 9]])
  }

  @Test
  func `Reset Recovers A Stream Whose Parser Threw`() throws {
    var stream = PartialsStream(initialValue: StreamArray<Int>(), from: .json())
    #expect(throws: JSONParsingError.self) {
      try stream.next(UInt8(ascii: "@"))
    }
    #expect(throws: StreamParsingError.parserFailed) {
      try stream.next(UInt8(ascii: "1"))
    }

    stream.reset(to: StreamArray<Int>())
    for byte in "[4,5]".utf8 {
      try stream.next(byte)
    }
    let finished = try stream.finish()
    expectNoDifference(finished, [4, 5])
  }

  // A sink rejection is a parser throw with a `streamFailure` left on the sink. The reset must
  // clear it: left set, the next document's first token re-reports the stale failure.
  @Test(arguments: [false, true])
  func `Reset Recovers A Stream Whose Sink Rejected A Token`(byteFed: Bool) throws {
    var stream = PartialsStream(initialValue: StreamArray<Int>(), from: .json())
    let error = #expect(throws: JSONParsingError.self) {
      try feed(&stream, #"[1,"x",2]"#, byteFed: byteFed)
    }
    expectNoDifference(
      error?.reason, .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
    )
    #expect(throws: StreamParsingError.parserFailed) {
      try stream.next(UInt8(ascii: "]"))
    }

    stream.reset(to: StreamArray<Int>())
    try feed(&stream, "[4,5]", byteFed: byteFed)
    expectNoDifference(try stream.finishAndReset(to: StreamArray<Int>()), [4, 5])
    try feed(&stream, "[6]", byteFed: byteFed)
    expectNoDifference(try stream.finishAndReset(to: StreamArray<Int>()), [6])
  }

  // The same, with the rejected token only completed by `finishAndReset(to:)`, which throws
  // rather than resetting.
  @Test
  func `Reset Recovers After Finish Value Resetting Reports A Sink Rejection`() throws {
    var stream = PartialsStream(initialValue: Int8(0), from: .json())
    try stream.next(Array("300".utf8))
    let error = #expect(throws: JSONParsingError.self) {
      _ = try stream.finishAndReset(to: 0)
    }
    expectNoDifference(
      error?.reason, .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch))
    )

    stream.reset(to: 0)
    try stream.next(Array("7".utf8))
    expectNoDifference(try stream.finishAndReset(to: 0), 7)
    try stream.next(Array("-8".utf8))
    expectNoDifference(try stream.finishAndReset(to: 0), -8)
  }

  @Test
  func `Reset Discards A Document Mid Parse`() throws {
    var stream = PartialsStream(initialValue: StreamArray<Int>(), from: .json())
    // Stop inside an open number token so the parser holds buffered bytes, an open container,
    // and the sink an open element.
    for byte in "[1,2,34".utf8 {
      try stream.next(byte)
    }
    expectNoDifference(stream.current, [1, 2])

    stream.reset(to: StreamArray<Int>())
    for byte in "[6]".utf8 {
      try stream.next(byte)
    }
    let finished = try stream.finish()
    expectNoDifference(finished, [6])
  }

  @Test
  func `Finish Value Throws After Parser Throws`() throws {
    var stream = PartialsStream(initialValue: 0, from: .json())
    #expect(throws: JSONParsingError.self) {
      _ = try stream.next(UInt8(ascii: "@"))
    }
    do {
      _ = try stream.finishPartial()
      Issue.record("finishPartial succeeded after the parser threw")
    } catch let error as StreamParsingError {
      expectNoDifference(error, .parserFailed)
    }
  }
}

private func feed<Value: StreamPartial>(
  _ stream: inout PartialsStream<Value>, _ json: String, byteFed: Bool
) throws {
  guard byteFed else { return try stream.next(Array(json.utf8)) }
  for byte in json.utf8 { try stream.next(byte) }
}
