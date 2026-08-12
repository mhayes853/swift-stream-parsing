import CustomDump
import StreamParsing
import Testing

@Suite
struct `PartialsSequence Tests` {
  @Test
  func `Emits Partial For Each Chunked Byte Input`() throws {
    let byteStream: [[UInt8]] = [Array("[1,2,3]".utf8)]

    let partials = try byteStream.partials(initialValue: [Int](), from: .json())
    expectNoDifference(partials, [[1, 2, 3], [1, 2, 3]])
  }

  @Test
  func `Emits Partial For Each Byte`() throws {
    let byteStream = Array("[1,2,3]".utf8)

    let partials = try byteStream.partials(initialValue: [Int](), from: .json())
    expectNoDifference(
      partials,
      [[], [], [1], [1], [1, 2], [1, 2], [1, 2, 3], [1, 2, 3]]
    )
  }

  // A digit does not produce a value until the token ends, so the states either side of it are
  // the same. This is the shape callers see when rendering a stream as it arrives.
  @Test
  func `Emits Same Partial When No Reduction Occurs For Byte`() throws {
    let byteStream = Array(#""ab""#.utf8)

    let partials = try byteStream.partials(initialValue: "", from: .json())
    expectNoDifference(partials, ["", "a", "ab", "ab", "ab"])
  }

  @Test
  func `Collects Partials For A Parseable Type`() throws {
    let partials = try Array(#"{"id":1}"#.utf8).partials(of: SequenceModel.self, from: .json())
    expectNoDifference(partials.last?.id, 1)
  }
}

@StreamParseable
struct SequenceModel: Equatable {
  var id: Int = 0
}
