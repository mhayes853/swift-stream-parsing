import Benchmark
import StreamParsingCore

private struct SpanDictionaryAllocationSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  var dictionary = StreamDictionary<Int>()
  var pendingValue: UnsafeMutableRawPointer?

  mutating func beginObject() {}
  mutating func endObject() {}
  mutating func beginArray() {}
  mutating func endArray() {}

  mutating func key(_ bytes: Span<UInt8>) {
    self.pendingValue = self.dictionary._openValue(forKey: bytes, initial: 0)
  }

  mutating func keyBegin() {}
  mutating func keyChunk(_ bytes: Span<UInt8>) {}
  mutating func keyEnd() {}

  mutating func string(_ bytes: Span<UInt8>) {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    guard let pendingValue = self.pendingValue,
          let value = Int(streamParsing: bytes, info: info)
    else { return }
    pendingValue.assumingMemoryBound(to: Int.self).pointee = value
    if !info.flags.contains(.incomplete) { self.pendingValue = nil }
  }

  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}

private struct MaterializingDictionaryAllocationSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  var values = [String: Int]()
  var currentKey = ""

  mutating func beginObject() {}
  mutating func endObject() {}
  mutating func beginArray() {}
  mutating func endArray() {}

  mutating func key(_ bytes: Span<UInt8>) {
    self.currentKey = bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
  }

  mutating func keyBegin() {}
  mutating func keyChunk(_ bytes: Span<UInt8>) {}
  mutating func keyEnd() {}

  mutating func string(_ bytes: Span<UInt8>) {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = Int(streamParsing: bytes, info: info) else { return }
    self.values[self.currentKey] = value
  }

  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}

func dictionaryAllocationBenchmarks() {
  var configuration = Benchmark.defaultConfiguration
  configuration.metrics = [.wallClock, .mallocCountTotal]

  Benchmark(
    "Dictionary repeated long keys - span open value",
    configuration: configuration
  ) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(runSpanDictionaryAllocation(Payloads.repeatedLongKeyDocument))
    }
  }

  Benchmark(
    "Dictionary repeated long keys - materializing key",
    configuration: configuration
  ) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(runMaterializingDictionaryAllocation(Payloads.repeatedLongKeyDocument))
    }
  }
}

@inline(never)
private func runSpanDictionaryAllocation(_ payload: [UInt8]) -> Int {
  var sink = SpanDictionaryAllocationSink()
  return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { buffer in
    var parser = JSONParser(buffer: buffer)
    payload.withUnsafeBufferPointer { input in
      try! parser.parse(input, into: &sink)
    }
    try! parser.finish(into: &sink)
    return sink.dictionary.count
  }
}

@inline(never)
private func runMaterializingDictionaryAllocation(_ payload: [UInt8]) -> Int {
  var sink = MaterializingDictionaryAllocationSink()
  return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { buffer in
    var parser = JSONParser(buffer: buffer)
    payload.withUnsafeBufferPointer { input in
      try! parser.parse(input, into: &sink)
    }
    try! parser.finish(into: &sink)
    return sink.values.count
  }
}
