import Testing

import StreamParsingCore

// Reads the sixteen bytes past the end of every key span, which is what a generated matcher
// does when it loads a whole vector regardless of the key's length. If the parser ever hands
// out a span pointing into the input near a chunk boundary, this reads past the buffer and the
// invariant is broken rather than merely untested.
struct KeyPaddingSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  private(set) var keys = [String]()
  private(set) var paddingWasZeroed = true

  mutating func key(_ bytes: Span<UInt8>) {
    bytes.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return }
      self.keys.append(String(decoding: buffer, as: UTF8.self))
      for offset in 0..<StreamParsingLayout.keyPaddingByteCount {
        if base[buffer.count + offset] != 0 { self.paddingWasZeroed = false }
      }
    }
  }

  mutating func beginObject() {}
  mutating func endObject() {}
  mutating func beginArray() {}
  mutating func endArray() {}
  mutating func keyBegin() {}
  mutating func keyChunk(_ bytes: Span<UInt8>) {}
  mutating func keyEnd() {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {}
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}

private func parse<Sink: StreamParseSink>(
  _ json: String,
  into sink: inout Sink,
  chunk: Int = .max,
  buffer: UnsafeMutableBufferPointer<UInt8>? = nil
) throws {
  var parser = buffer.map { JSONParser(buffer: $0) } ?? JSONParser()
  let bytes = Array(json.utf8)
  try bytes.withUnsafeBufferPointer { input in
    var i = 0
    while i < input.count {
      let count = min(chunk, input.count - i)
      let slice = UnsafeBufferPointer(start: input.baseAddress! + i, count: count)
      try parser.parse(slice, into: &sink)
      i += count
    }
  }
  try parser.finish(into: &sink)
}

@Suite
struct `JSON parser buffer tests` {
  // MARK: - Key padding

  @Test
  func `Key spans carry readable zeroed padding`() throws {
    var sink = KeyPaddingSink()
    try parse(#"{"id":1,"name":"a","aLongerKeyName":2}"#, into: &sink)
    #expect(sink.keys == ["id", "name", "aLongerKeyName"])
    #expect(sink.paddingWasZeroed)
  }

  // A key whose closing quote is the final byte of a chunk is the case where handing out a
  // span into the input would read past the caller's buffer.
  @Test
  func `Key padding holds when a key ends at a chunk boundary`() throws {
    let json = #"{"name":1}"#
    let bytes = Array(json.utf8)
    for split in 1..<bytes.count {
      var sink = KeyPaddingSink()
      try parse(json, into: &sink, chunk: split)
      #expect(sink.keys == ["name"], "split \(split)")
      #expect(sink.paddingWasZeroed, "split \(split)")
    }
  }

  @Test
  func `Key padding holds byte by byte`() throws {
    var sink = KeyPaddingSink()
    try parse(#"{"alpha":1,"beta":2}"#, into: &sink, chunk: 1)
    #expect(sink.keys == ["alpha", "beta"])
    #expect(sink.paddingWasZeroed)
  }

  // MARK: - Buffer exhaustion

  @Test
  func `A caller supplied buffer that is too small fails cleanly`() throws {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 64)
    defer { storage.deallocate() }
    storage.initialize(repeating: 0)

    let key = String(repeating: "k", count: 200)
    var sink = KeyPaddingSink()
    let error = #expect(throws: JSONParsingError.self) {
      try parse("{\"\(key)\":1}", into: &sink, buffer: storage)
    }
    #expect(error?.reason == .bufferExhausted)
  }

  @Test
  func `A caller supplied buffer handles keys that fit`() throws {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 128)
    defer { storage.deallocate() }
    storage.initialize(repeating: 0)

    var sink = KeyPaddingSink()
    try parse(#"{"reasonablyLongKeyName":1}"#, into: &sink, buffer: storage)
    #expect(sink.keys == ["reasonablyLongKeyName"])
    #expect(sink.paddingWasZeroed)
  }

  // A number contained in one chunk is already contiguous and is handed over in place, so the
  // buffer size does not limit it.
  @Test
  func `A number longer than the buffer parses when it arrives whole`() throws {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 64)
    defer { storage.deallocate() }
    storage.initialize(repeating: 0)

    var sink = KeyPaddingSink()
    let digits = String(repeating: "1", count: 200)
    try parse("[\(digits)]", into: &sink, buffer: storage)
  }

  // Spanning a chunk boundary is what forces the copy, and there the buffer size does apply.
  @Test
  func `A number spanning chunks beyond the buffer fails cleanly`() throws {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 64)
    defer { storage.deallocate() }
    storage.initialize(repeating: 0)

    var sink = KeyPaddingSink()
    let digits = String(repeating: "1", count: 200)
    let error = #expect(throws: JSONParsingError.self) {
      try parse("[\(digits)]", into: &sink, chunk: 1, buffer: storage)
    }
    #expect(error?.reason == .bufferExhausted)
  }
}
