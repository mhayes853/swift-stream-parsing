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
    self.pendingValue = nil
  }

  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}

// The materialising comparison sink this file used to carry has been removed: it was a prototype
// of what the parser would cost without `_openValue`, and that comparison is settled and recorded
// in NEW_ARCHITECTURE.md. The span row below is kept as a malloc-count regression guard on the
// shipped path — a repeated long key must not allocate per occurrence.
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
