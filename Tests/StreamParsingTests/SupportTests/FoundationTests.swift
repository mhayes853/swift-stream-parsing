import CustomDump
import Foundation
import StreamParsing
import Testing

@Suite
struct `Foundation tests` {
  @Test
  func `Data Reducer Applies Parsed String Through PartialsStream`() throws {
    let expected = Data("hello".utf8)
    let parser = MockParser<Data>(actions: [0x00: .string("hello")])
    var stream = PartialsStream(initialValue: Data(), from: parser)

    let result = try stream.next(0x00)

    expectNoDifference(result, expected)
    expectNoDifference(stream.current, expected)
  }
}
