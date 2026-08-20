import CustomDump
import Testing

import StreamParsingCore

// Records every key and where its span pointed. A key that arrives whole inside a chunk is a
// borrow into the parser's input; one the chunk cuts is reassembled in the parser's buffer. Both
// deliver the same bytes, and the test below pins which is which.
struct KeyRecordingSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  private(set) var keys = [String]()
  private(set) var keyAddresses = [UnsafeRawPointer?]()

  mutating func key(_ bytes: Span<UInt8>) {
    bytes.withUnsafeBufferPointer { buffer in
      self.keys.append(String(decoding: buffer, as: UTF8.self))
      self.keyAddresses.append(buffer.baseAddress.map(UnsafeRawPointer.init))
    }
  }

  mutating func beginObject() {}
  mutating func endObject() {}
  mutating func beginArray() {}
  mutating func endArray() {}
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
  // MARK: - Key delivery

  @Test
  func `Keys arriving whole in one chunk are spans into the input`() throws {
    let json = #"{"id":1,"name":"a","aLongerKeyName":2}"#
    let bytes = Array(json.utf8)
    var sink = KeyRecordingSink()
    var parser = JSONParser()
    try bytes.withUnsafeBufferPointer { input in
      try parser.parse(input, into: &sink)
      try parser.finish(into: &sink)
      let start = UnsafeRawPointer(input.baseAddress!)
      let end = start + input.count
      expectNoDifference(sink.keys, ["id", "name", "aLongerKeyName"])
      for address in sink.keyAddresses {
        #expect(address.map { $0 >= start && $0 < end } == true)
      }
    }
  }

  // A key the chunk cuts is reassembled in the parser's buffer, and a key whose closing quote is
  // the final byte of a chunk is the case where a span into the input would have been wrong — the
  // parser cannot tell the quote from more key until the next chunk arrives.
  @Test
  func `Keys split across chunks are delivered whole at every split`() throws {
    let json = #"{"name":1}"#
    let bytes = Array(json.utf8)
    for split in 1..<bytes.count {
      var sink = KeyRecordingSink()
      try parse(json, into: &sink, chunk: split)
      expectNoDifference(sink.keys, ["name"], "split \(split)")
    }
  }

  @Test
  func `Keys fed byte by byte come from the buffer, whole`() throws {
    let json = #"{"alpha":1,"beta":2}"#
    let bytes = Array(json.utf8)
    var sink = KeyRecordingSink()
    try bytes.withUnsafeBufferPointer { input in
      var parser = JSONParser()
      for byte in input {
        try parser.parse(byte: byte, into: &sink)
      }
      try parser.finish(into: &sink)
      let start = UnsafeRawPointer(input.baseAddress!)
      let end = start + input.count
      expectNoDifference(sink.keys, ["alpha", "beta"])
      for address in sink.keyAddresses {
        #expect(address.map { $0 >= start && $0 < end } == false)
      }
    }
  }

  // MARK: - Buffer exhaustion

  // A key contained in one chunk is handed over in place, like a number, so the buffer size does
  // not limit it. Spanning a chunk boundary is what forces the copy, and there the size applies.
  @Test
  func `A key longer than the buffer parses when it arrives whole`() throws {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 64)
    defer { storage.deallocate() }
    storage.initialize(repeating: 0)

    let key = String(repeating: "k", count: 200)
    var sink = KeyRecordingSink()
    try parse("{\"\(key)\":1}", into: &sink, buffer: storage)
    expectNoDifference(sink.keys, [key])
  }

  @Test
  func `A key spanning chunks beyond the buffer fails cleanly`() throws {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 64)
    defer { storage.deallocate() }
    storage.initialize(repeating: 0)

    let key = String(repeating: "k", count: 200)
    var sink = KeyRecordingSink()
    let error = #expect(throws: JSONParsingError.self) {
      try parse("{\"\(key)\":1}", into: &sink, chunk: 50, buffer: storage)
    }
    expectNoDifference(error?.reason, .bufferExhausted)
  }

  @Test
  func `A caller supplied buffer handles keys that fit`() throws {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 128)
    defer { storage.deallocate() }
    storage.initialize(repeating: 0)

    var sink = KeyRecordingSink()
    try parse(#"{"reasonablyLongKeyName":1}"#, into: &sink, buffer: storage)
    expectNoDifference(sink.keys, ["reasonablyLongKeyName"])
  }

  // A number contained in one chunk is already contiguous and is handed over in place, so the
  // buffer size does not limit it.
  @Test
  func `A number longer than the buffer parses when it arrives whole`() throws {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 64)
    defer { storage.deallocate() }
    storage.initialize(repeating: 0)

    var sink = KeyRecordingSink()
    let digits = String(repeating: "1", count: 200)
    try parse("[\(digits)]", into: &sink, buffer: storage)
  }

  // Spanning a chunk boundary is what forces the copy, and there the buffer size does apply.
  @Test
  func `A number spanning chunks beyond the buffer fails cleanly`() throws {
    let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 64)
    defer { storage.deallocate() }
    storage.initialize(repeating: 0)

    var sink = KeyRecordingSink()
    let digits = String(repeating: "1", count: 200)
    let error = #expect(throws: JSONParsingError.self) {
      try parse("[\(digits)]", into: &sink, chunk: 1, buffer: storage)
    }
    expectNoDifference(error?.reason, .bufferExhausted)
  }
}
