import CustomDump
import StreamParsing
import StreamParsingCore
import Testing

@Suite
struct `PartialsSequence Tests` {
  @Test
  func `Emits Partial For Each Chunked Byte Input`() throws {
    let byteStream: [[UInt8]] = [Array("[1,2,3]".utf8)]

    let partials = try byteStream.partials(initialValue: StreamArray<Int>(), from: .json())
    expectNoDifference(partials, [[1, 2, 3], [1, 2, 3]])
  }

  @Test
  func `Collects Partials For A Parseable Type`() throws {
    let partials = try Array(#"{"id":1}"#.utf8).partials(of: SequenceModel.self, from: .json())
    expectNoDifference(partials.last?.id, 1)
  }

  // `partials(of:from:)` has one overload constrained to `StreamParseable` and one to
  // `StreamParseableRoot`, and nothing orders them for a type that conforms to both --
  // `StreamEmptyObject` does, and so does any macro `Partial` that is itself `StreamParseable`.
  // This fails to compile if the ordering is ever lost.
  @Test
  func `Partials resolves for a type that is both StreamParseable and a root`() throws {
    let partials = try Array("{}".utf8).partials(of: StreamEmptyObject.self, from: .json())
    expectNoDifference(partials, [StreamEmptyObject(), StreamEmptyObject(), StreamEmptyObject()])
  }
}

@StreamParseable
struct SequenceModel: Equatable {
  var id: Int = 0
}
