import CustomDump
import StreamParsing
import Testing

@Suite
struct `AsyncPartialsSequence Tests` {
  @Test
  func `Emits Partial For Each Chunked Async Byte Input`() async throws {
    let byteStream = AsyncStream<[UInt8]> { continuation in
      continuation.yield(Array("[1,2".utf8))
      continuation.yield(Array(",3]".utf8))
      continuation.finish()
    }

    var partials = [StreamArray<Int>]()
    for try await partial in byteStream.partials(initialValue: StreamArray<Int>(), from: .json()) {
      partials.append(partial)
    }

    expectNoDifference(partials, [[1, 2], [1, 2, 3]])
  }

  @Test
  func `Emits Partial For Each Async Byte`() async throws {
    let byteStream = AsyncStream<UInt8> { continuation in
      for byte in "[1,2]".utf8 { continuation.yield(byte) }
      continuation.finish()
    }

    var partials = [StreamArray<Int>]()
    for try await partial in byteStream.partials(initialValue: StreamArray<Int>(), from: .json()) {
      partials.append(partial)
    }

    expectNoDifference(partials, [[], [1], [1], [1, 2], [1, 2]])
  }

  @Test
  func `Emits Same Partial When No Reduction Occurs For An Async Byte`() async throws {
    let byteStream = AsyncStream<UInt8> { continuation in
      for byte in #""ab""#.utf8 { continuation.yield(byte) }
      continuation.finish()
    }

    var partials = [String]()
    for try await partial in byteStream.partials(initialValue: "", from: .json()) {
      partials.append(partial)
    }

    expectNoDifference(partials, ["", "a", "ab", "ab"])
  }

  // The iterator holds the stream in a box, since PartialsStream owns a parser buffer and an
  // allocation the sink points into and cannot be copied. Iterating to completion is what proves
  // the box hands back the same stream each time rather than a fresh one.
  @Test
  func `Parses A Model Across Async Chunks`() async throws {
    let byteStream = AsyncStream<[UInt8]> { continuation in
      continuation.yield(Array(#"{"id":4,"na"#.utf8))
      continuation.yield(Array(#"me":"Blob"}"#.utf8))
      continuation.finish()
    }

    var partials = [AsyncModel.Partial]()
    for try await partial in byteStream.partials(of: AsyncModel.self, from: .json()) {
      partials.append(partial)
    }

    expectNoDifference(partials.last?.id, 4)
    expectNoDifference(partials.last?.name, "Blob")
  }

  @Test
  func `Propagates A Parsing Failure`() async throws {
    let byteStream = AsyncStream<UInt8> { continuation in
      for byte in "@".utf8 { continuation.yield(byte) }
      continuation.finish()
    }

    await #expect(throws: JSONParsingError.self) {
      for try await _ in byteStream.partials(initialValue: 0, from: .json()) {}
    }
  }
}

@StreamParseable
struct AsyncModel: Equatable {
  var id: Int = 0
  var name: String = ""
}
