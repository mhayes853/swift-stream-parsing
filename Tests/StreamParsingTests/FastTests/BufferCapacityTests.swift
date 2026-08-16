import Testing

import StreamParsing
import StreamParsingCore

// The parser's buffer holds one token at a time — a key, a number, or the decoded body of an
// escaped string — so `bufferCapacity` is the longest single token a document may contain, not
// the longest document. That distinction is the whole of the setting, and it was pinned only for
// one caller-supplied case. `BufferCapacityBenchmarks` measures the same axis.
//
// A token that fits entirely inside one chunk is emitted from the input directly and never
// reaches the buffer, so every case here also has to be fed in pieces to mean anything.
@Suite
struct `Buffer capacity tests` {
  private static func parse(_ json: String, capacity: Int, chunk: Int) throws {
    var parser = JSONParser(bufferCapacity: capacity)
    var sink = CountingConformanceSink()
    let bytes = Array(json.utf8)
    try bytes.withUnsafeBufferPointer { input in
      var i = 0
      while i < input.count {
        let count = Swift.min(chunk, input.count - i)
        try parser.parse(UnsafeBufferPointer(start: input.baseAddress! + i, count: count), into: &sink)
        i += count
      }
    }
    try parser.finish(into: &sink)
  }

  private static func failure(_ json: String, capacity: Int, chunk: Int) -> JSONParsingError? {
    do {
      try Self.parse(json, capacity: capacity, chunk: chunk)
      return nil
    } catch let error as JSONParsingError {
      return error
    } catch {
      return nil
    }
  }

  // The initializer floors capacity at 64, so a request below that is not a way to make the
  // buffer smaller than the parser needs to function.
  @Test(arguments: [0, 1, 16, 63, 64])
  func `Capacity is floored at sixty four bytes`(capacity: Int) throws {
    let key = String(repeating: "k", count: 48)
    try Self.parse("{\"\(key)\":1}", capacity: capacity, chunk: 1)
  }

  @Test(arguments: [64, 256, 4_096])
  func `A token shorter than capacity parses byte by byte`(capacity: Int) throws {
    let key = String(repeating: "k", count: capacity - 16)
    try Self.parse("{\"\(key)\":1}", capacity: capacity, chunk: 1)
  }

  // Each of the three token kinds that buffer, past a capacity that cannot hold it.
  @Test
  func `A key longer than capacity is rejected`() {
    let key = String(repeating: "k", count: 4_096)
    #expect(Self.failure("{\"\(key)\":1}", capacity: 64, chunk: 1)?.reason == .bufferExhausted)
  }

  @Test
  func `A number longer than capacity is rejected`() {
    let number = String(repeating: "9", count: 4_096)
    #expect(Self.failure("[\(number)]", capacity: 64, chunk: 1)?.reason == .bufferExhausted)
  }

  // Strings are the exception, and both halves of it are worth pinning because the useful
  // statement is narrower than "capacity is the longest token": only keys and numbers have to
  // arrive whole. A string is emitted as chunks, so it drains the buffer as it fills it and its
  // length is bounded by nothing — with escapes or without.
  @Test(arguments: [1, 7, 64])
  func `A string is not bounded by capacity`(chunk: Int) throws {
    let plain = String(repeating: "a", count: 16_384)
    try Self.parse("[\"\(plain)\"]", capacity: 64, chunk: chunk)

    let escaped = String(repeating: #"\n"#, count: 8_192)
    try Self.parse("[\"\(escaped)\"]", capacity: 64, chunk: chunk)
  }

  // Draining as it fills is only safe if the content still comes out whole and in order, so the
  // same string is read back through the convenience layer at a capacity far below its length.
  @Test(arguments: [1, 7, 64])
  func `A string longer than capacity decodes intact`(chunk: Int) throws {
    let body = String(repeating: #"escaped\n\"body\" "#, count: 512)
    let expected = String(repeating: "escaped\n\"body\" ", count: 512)
    let json = Array(#"{"title":"t","body":"\#(body)"}"#.utf8)

    var stream = PartialsStream(initialValue: CapacityDocument.Partial(), from: .json(bufferCapacity: 64))
    var index = 0
    while index < json.count {
      let end = Swift.min(index + chunk, json.count)
      try stream.next(json[index..<end])
      index = end
    }
    let document = try stream.finish()
    #expect(document.body == expected)
  }

  // The failure is a property of the token and the capacity, not of where the chunks fell.
  @Test(arguments: [1, 3, 7, 64])
  func `Exhaustion does not depend on chunking`(chunk: Int) {
    let key = String(repeating: "k", count: 512)
    #expect(
      Self.failure("{\"\(key)\":1}", capacity: 64, chunk: chunk)?.reason == .bufferExhausted
    )
  }

  // The convenience layer carries the same setting through `JSONStreamFormat`, and it has to
  // reach the parser rather than being dropped on the way.
  @Test
  func `The stream format carries capacity to the parser`() throws {
    let key = String(repeating: "k", count: 512)
    let json = Array("{\"\(key)\":1}".utf8)

    var wide = PartialsStream(initialValue: CapacityCounts.Partial(), from: .json(bufferCapacity: 4_096))
    for byte in json { try wide.next(byte) }
    _ = try wide.finish()

    var narrow = PartialsStream(initialValue: CapacityCounts.Partial(), from: .json(bufferCapacity: 64))
    #expect(throws: JSONParsingError.self) {
      for byte in json { try narrow.next(byte) }
      _ = try narrow.finish()
    }
  }
}

@StreamParseable
private struct CapacityCounts: Equatable {
  var counts: [String: Int] = [:]
}

@StreamParseable
private struct CapacityDocument: Equatable {
  var title: String = ""
  var body: String = ""
}
