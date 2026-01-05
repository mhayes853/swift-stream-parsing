import CustomDump
import StreamParsing
import Testing

@Suite
struct `AsyncPartialsSequence Tests` {
  @Test
  func `Emits Partial For Each Chunked Async Byte Input`() async throws {
    let parser = MockParser<Int>(actions: [0x00: .int(1), 0x01: .int(2), 0x02: .int(3)])
    let byteStream = AsyncStream<[UInt8]> { continuation in
      continuation.yield([0x00, 0x01, 0x02])
      continuation.finish()
    }

    var partials = [Int]()
    let stream = byteStream.partials(initialValue: 0, from: parser)
    for try await partial in stream {
      partials.append(partial)
    }

    expectNoDifference(partials, [3])
  }

  @Test
  func `Emits Partial For Each Async Byte`() async throws {
    let parser = MockParser<Int>(actions: [0x00: .int(1), 0x01: .int(2), 0x02: .int(3)])
    let byteStream = AsyncStream<UInt8> { continuation in
      continuation.yield(0x00)
      continuation.yield(0x01)
      continuation.yield(0x02)
      continuation.finish()
    }

    var partials = [Int]()
    let stream = byteStream.partials(initialValue: 0, from: parser)
    for try await partial in stream {
      partials.append(partial)
    }

    expectNoDifference(partials, [1, 2, 3])
  }

  @Test
  func `Emits Same Partial When No Reduction Occurs For An Async Byte`() async throws {
    let parser = MockParser<Int>(actions: [0x00: .int(1), 0x02: .int(3)])
    let byteStream = AsyncStream<UInt8> { continuation in
      continuation.yield(0x00)
      continuation.yield(0x01)
      continuation.yield(0x02)
      continuation.finish()
    }

    var partials = [Int]()
    let stream = byteStream.partials(initialValue: 0, from: parser)
    for try await partial in stream {
      partials.append(partial)
    }

    expectNoDifference(partials, [1, 1, 3])
  }
}
