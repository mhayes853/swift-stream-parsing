import CustomDump
import Testing

import StreamParsingCore

// `StreamParseSink.commit()` is the lifetime signal: every parse call that delivered something ends
// with it, before the memory its spans borrowed can change. `parse(byte:)` has a one-byte fast path
// for a string value's content that delivers through the parser's escape scratch, which the next
// byte overwrites -- so its commit is what keeps a deferring sink's borrowed bytes meaningful.
@Suite
struct `Parse call commit tests` {
  // Logs every call, and defers each chunk's bytes the way the contract allows: the borrowed
  // region is remembered and only read at the next `commit()`.
  private struct DeferringLog: StreamParseSink {
    var log: [String] = []
    var committedText: [UInt8] = []
    private var deferred: [UnsafeRawBufferPointer] = []

    mutating func beginObject() -> StreamContainerDisposition {
      self.log.append("{")
      return .stream
    }
    mutating func endObject() { self.log.append("}") }
    mutating func beginArray() -> StreamContainerDisposition {
      self.log.append("[")
      return .stream
    }
    mutating func endArray() { self.log.append("]") }
    mutating func key(_ bytes: Span<UInt8>) { self.log.append("key") }
    mutating func stringBegin() { self.log.append("str(") }
    mutating func stringChunk(_ bytes: Span<UInt8>) {
      self.log.append("chunk")
      self.deferred.append(bytes.withUnsafeBytes { $0 })
    }
    mutating func stringEnd() { self.log.append("str)") }
    mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) { self.log.append("num") }
    mutating func boolean(_ value: Bool) { self.log.append("bool") }
    mutating func null() { self.log.append("null") }

    mutating func commit() {
      for region in self.deferred { self.committedText.append(contentsOf: region) }
      self.deferred.removeAll()
      self.log.append("commit")
    }

    var streamFailure: StreamSinkFailure? { nil }
  }

  @Test
  func `Every byte-fed call that delivers ends with a commit`() throws {
    let document = Array(#"{"k":"hello, byte-fed world","n":[1,true]}"#.utf8)
    var parser = JSONParser()
    var sink = DeferringLog()
    for (offset, byte) in document.enumerated() {
      let before = sink.log.count
      try parser.parse(byte: byte, into: &sink)
      let delivered = sink.log[before...].contains { $0 != "commit" }
      if delivered {
        #expect(sink.log.last == "commit", "byte \(offset) delivered without a commit")
      }
    }
    try parser.finish(into: &sink)
    // Read at commit time, every deferred byte is still the byte it was delivered as.
    expectNoDifference(String(decoding: sink.committedText, as: UTF8.self), "hello, byte-fed world")
  }

  private struct EventLogConsumer: StreamEventBatchConsumer {
    var events: [String] = []
    var streamFailure: StreamSinkFailure? { nil }

    mutating func events(_ batch: borrowing StreamEventBatch) -> Int {
      let records = batch.records
      for index in 0..<batch.count {
        let bytes = String(decoding: streamCopy(batch.bytes(of: index)), as: UTF8.self)
        self.events.append("\(records[index].kind):\(bytes)")
      }
      return batch.count
    }
  }

  // The batching adapter flushes at `commit()`, so its consumer is never more than the current
  // parse call behind: after each byte it holds exactly the events a direct sink has seen.
  @Test
  func `The batching adapter's consumer is current after every byte`() throws {
    let document = Array(#"{"k":"streamed one byte at a time","v":"ok"}"#.utf8)
    var direct = JSONParser()
    var batched = JSONParser()
    var sink = StreamEventBatchingSink(consumer: EventLogConsumer())
    var expected = StreamEventBatchingSink(consumer: EventLogConsumer())
    for (offset, byte) in document.enumerated() {
      try batched.parse(byte: byte, into: &sink)
      // The oracle is a second adapter flushed by hand after the call, which cannot lag.
      try direct.parse(byte: byte, into: &expected)
      expected.commit()
      if sink.consumer.events != expected.consumer.events {
        expectNoDifference(sink.consumer.events, expected.consumer.events, "after byte \(offset)")
        return
      }
    }
    #expect(sink.consumer.events.contains("stringChunk:s"))
  }
}
