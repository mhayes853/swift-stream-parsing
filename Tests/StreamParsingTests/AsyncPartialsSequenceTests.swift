import CustomDump
import StreamParsing
import Testing

@Suite
struct `AsyncPartialsSequence Tests` {
  @Test
  func `Emits Partial For Each Chunked Async Byte Input And Completion`() async throws {
    let byteStream = AsyncStream<[UInt8]> { continuation in
      continuation.yield(Array("[1,2".utf8))
      continuation.yield(Array(",3]".utf8))
      continuation.finish()
    }

    var partials = [StreamArray<Int>]()
    for try await partial in byteStream.partials(initialValue: StreamArray<Int>(), from: .json()) {
      partials.append(partial)
    }

    expectNoDifference(partials, [[1], [1, 2, 3], [1, 2, 3]])
  }

  @Test
  func `Emits Partial For Each Async Byte And Completion`() async throws {
    let byteStream = AsyncStream<UInt8> { continuation in
      for byte in "[1,2]".utf8 { continuation.yield(byte) }
      continuation.finish()
    }

    var partials = [StreamArray<Int>]()
    for try await partial in byteStream.partials(initialValue: StreamArray<Int>(), from: .json()) {
      partials.append(partial)
    }

    expectNoDifference(partials, [[], [], [1], [1], [1, 2], [1, 2]])
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

    expectNoDifference(partials, ["", "a", "ab", "ab", "ab"])
  }

  @Test
  func `Emits A Number Finalized At End Of Input`() async throws {
    let byteStream = AsyncStream<UInt8> { continuation in
      continuation.yield(0x31)
      continuation.finish()
    }

    var partials = [Int]()
    for try await partial in byteStream.partials(initialValue: 0, from: .json()) {
      partials.append(partial)
    }

    expectNoDifference(partials, [0, 1])
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

  @Test
  func `Rejects A Second Subscriber`() async throws {
    let partials = AsyncBytes(bytes: Array("1".utf8))
      .partials(initialValue: 0, from: .json())
    var first = partials.makeAsyncIterator()
    var second = partials.makeAsyncIterator()

    let firstPartial = try await first.next()
    expectNoDifference(firstPartial, 0)
    await #expect(throws: StreamParsingError.multipleSubscribers) {
      _ = try await second.next()
    }
    let final = try await first.next()
    expectNoDifference(final, 1)
    let end = try await first.next()
    expectNoDifference(end, nil)
  }

  @Test
  func `Iterator Copies Share One Subscription`() async throws {
    let partials = AsyncBytes(bytes: Array("1".utf8))
      .partials(initialValue: 0, from: .json())
    var first = partials.makeAsyncIterator()
    var copy = first

    let firstPartial = try await first.next()
    expectNoDifference(firstPartial, 0)
    let final = try await copy.next()
    expectNoDifference(final, 1)
    let end = try await first.next()
    expectNoDifference(end, nil)
  }
}

private struct AsyncBytes: AsyncSequence, Hashable, Sendable {
  let bytes: [UInt8]

  struct AsyncIterator: AsyncIteratorProtocol, Hashable, Sendable {
    let bytes: [UInt8]
    var index = 0

    mutating func next() async -> UInt8? {
      guard self.index < self.bytes.count else { return nil }
      defer { self.index += 1 }
      return self.bytes[self.index]
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(bytes: self.bytes)
  }
}

@StreamParseable
struct AsyncModel: Equatable {
  var id: Int = 0
  var name: String = ""
}
