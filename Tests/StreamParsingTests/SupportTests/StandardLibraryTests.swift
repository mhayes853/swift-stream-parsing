import CustomDump
import StreamParsing
import Testing

@Suite
struct `StandardLibrary tests` {
  @Test
  func `Optional Reducer Applies Parsed Value Through PartialsStream`() throws {
    let parser = MockParser<Int?>(actions: [0x00: .int(42)])
    var stream = PartialsStream(initialValue: nil, from: parser)

    let result = try stream.next(0x00)

    expectNoDifference(result, .some(42))
    expectNoDifference(stream.current, .some(42))
  }

  @Test
  func `Optional Reducer Applies Nil Through PartialsStream`() throws {
    let parser = MockParser<Int?>(actions: [0x00: .nilValue])
    var stream = PartialsStream(initialValue: .some(1), from: parser)

    let result = try stream.next(0x00)

    expectNoDifference(result, nil)
    expectNoDifference(stream.current, nil)
  }

  @Test
  func `Array Reducer Sets Existing Member Through PartialsStream`() throws {
    let parser = MockParser<[Int]>(
      actions: [
        0x00: .arraySet(index: 0, value: 7),
        0x01: .arrayAppend
      ]
    )
    var stream = PartialsStream(initialValue: [], from: parser)

    let result = try stream.next([0x01, 0x00])

    expectNoDifference(result, [7])
    expectNoDifference(stream.current, [7])
  }
}
