import Benchmark
import StreamParsingCore

struct FastCountingSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  var checksum: UInt64 = 0
  var tokens = 0

  mutating func beginObject() { self.tokens &+= 1 }
  mutating func endObject() {}
  mutating func beginArray() { self.tokens &+= 1 }
  mutating func endArray() {}

  mutating func key(_ bytes: Span<UInt8>) {
    self.tokens &+= 1
    self.checksum &+= bytes.paddedLeadingWord()
  }

  mutating func string(_ bytes: Span<UInt8>) {
    self.tokens &+= 1
    self.checksum &+= UInt64(bytes.count)
  }

  mutating func keyBegin() {}
  mutating func keyChunk(_ bytes: Span<UInt8>) { self.checksum &+= bytes.paddedLeadingWord() }
  mutating func keyEnd() {}
  mutating func stringBegin() { self.tokens &+= 1 }
  mutating func stringChunk(_ bytes: Span<UInt8>) { self.checksum &+= UInt64(bytes.count) }
  mutating func stringEnd() {}

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.tokens &+= 1
    self.checksum &+= info.magnitude
  }

  mutating func boolean(_ value: Bool) { self.tokens &+= 1 }
  mutating func null() { self.tokens &+= 1 }
}

func addFastParserBenchmarks() {
  var payloadConfiguration = Benchmark.defaultConfiguration
  payloadConfiguration.metrics.append(contentsOf: [.throughput, payloadMegabytesPerSecond])

  let payloads: [(String, [UInt8])] = [
    ("Flat struct", Payloads.flat),
    ("Nested structs", Payloads.nested),
    ("Array of structs", Payloads.userList),
    ("Nested arrays", Payloads.matrix),
    ("Dictionary", Payloads.counts),
    ("Long string", Payloads.document),
    ("Escaped string", Payloads.escapedString),
    ("Unicode escaped string", Payloads.unicodeEscapedString),
    ("Non-ASCII string", Payloads.nonASCIIString),
    ("Pretty printed users", Payloads.prettyUserList),
    ("Twitter", Payloads.twitter),
  ]

  for (name, payload) in payloads {
    Benchmark(
      "Fast \(name) - bulk",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max) })
      }
    }

    Benchmark(
      "Fast \(name) - 64B chunks",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: 64) })
      }
    }

    Benchmark(
      "Fast \(name) - byte by byte",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParserByteAtATime(payload) })
      }
    }
  }
}

private func runFastParser(_ payload: [UInt8], chunk: Int) throws -> UInt64 {
  var parser = JSONParser()
  var sink = FastCountingSink()
  try payload.withUnsafeBufferPointer { buffer in
    var offset = 0
    while offset < buffer.count {
      let count = min(chunk, buffer.count - offset)
      let slice = UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: count)
      try parser.parse(slice, into: &sink)
      offset += count
    }
  }
  try parser.finish(into: &sink)
  return sink.checksum
}

private func runFastParserByteAtATime(_ payload: [UInt8]) throws -> UInt64 {
  var parser = JSONParser()
  var sink = FastCountingSink()
  for byte in payload {
    try parser.parse(byte: byte, into: &sink)
  }
  try parser.finish(into: &sink)
  return sink.checksum
}
