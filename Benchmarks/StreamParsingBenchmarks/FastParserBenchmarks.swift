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

// MARK: - Runners

// Shared by every payload-shaped benchmark in the suite, so a chunk size, a validation setting
// and a buffer capacity are all one call away from any of them.
func runFastParser(
  _ payload: [UInt8],
  chunk: Int,
  configuration: JSONParserConfiguration = .strict,
  bufferCapacity: Int = 4_096
) throws -> UInt64 {
  var parser = JSONParser(configuration: configuration, bufferCapacity: bufferCapacity)
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

func runFastParserByteAtATime(
  _ payload: [UInt8],
  configuration: JSONParserConfiguration = .strict
) throws -> UInt64 {
  var parser = JSONParser(configuration: configuration)
  var sink = FastCountingSink()
  for byte in payload {
    try parser.parse(byte: byte, into: &sink)
  }
  try parser.finish(into: &sink)
  return sink.checksum
}

var payloadConfiguration: Benchmark.Configuration {
  var configuration = Benchmark.defaultConfiguration
  configuration.metrics.append(contentsOf: [.throughput, payloadMegabytesPerSecond])
  return configuration
}

// MARK: - Registration

func addFastParserBenchmarks() {
  let payloads: [(String, [UInt8])] = [
    ("Flat struct", Payloads.flat),
    ("Nested structs", Payloads.nested),
    ("Array of structs", Payloads.userList),
    ("Nested arrays", Payloads.matrix),
    ("Dictionary", Payloads.counts),
    ("Literals", Payloads.literals),
    ("Long string", Payloads.document),
    ("Escaped string", Payloads.escapedString),
    ("Unicode escaped string", Payloads.unicodeEscapedString),
    ("Non-ASCII string", Payloads.nonASCIIString),
    ("Pretty printed users", Payloads.prettyUserList),
    ("Twitter", Payloads.twitter),
  ]

  for (name, payload) in payloads {
    Benchmark("Fast \(name) - bulk", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max) })
      }
    }

    Benchmark("Fast \(name) - 64B chunks", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: 64) })
      }
    }

    Benchmark("Fast \(name) - byte by byte", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParserByteAtATime(payload) })
      }
    }
  }

  // What validation costs. `JSONParserConfiguration.unchecked` is shipped and, until now, had no
  // number attached to it: every benchmark in the suite ran `.strict`. Paired against the `bulk`
  // rows above on the payloads where each of the three checks is actually exercised — literals
  // and number grammar everywhere, UTF-8 validation only where the bytes are not ASCII.
  let uncheckedPayloads: [(String, [UInt8])] = [
    ("Array of structs", Payloads.userList),
    ("Nested arrays", Payloads.matrix),
    ("Long string", Payloads.document),
    ("Non-ASCII string", Payloads.nonASCIIString),
    ("Twitter", Payloads.twitter),
  ]

  for (name, payload) in uncheckedPayloads {
    Benchmark("Fast \(name) - bulk unchecked", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max, configuration: .unchecked) })
      }
    }
  }
}
