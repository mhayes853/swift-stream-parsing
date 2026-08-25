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

  mutating func stringBegin() { self.tokens &+= 1 }
  mutating func stringChunk(_ bytes: Span<UInt8>) { self.checksum &+= UInt64(bytes.count) }
  mutating func stringEnd() {}

  // Every field of the info is folded in, deliberately: a sink that reads only the magnitude
  // lets the compiler drop the exponent, digit count and flag work on a directly emitted
  // number, which made the unbatched rows look cheaper than any real sink's path is.
  @inline(__always)
  static func fold(_ info: NumberInfo) -> UInt64 {
    info.magnitude &+ UInt64(bitPattern: Int64(info.exponent))
      &+ UInt64(info.digitCount) &+ UInt64(info.flags.rawValue)
  }

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.tokens &+= 1
    self.checksum &+= Self.fold(info)
  }

  // A run of numbers from the windowed path: the same checksum, without a call per number.
  mutating func numbers(_ batch: borrowing StreamNumberBatch) -> Int {
    let infos = batch.infos
    var sum: UInt64 = 0
    for i in 0..<batch.count { sum &+= Self.fold(infos[i]) }
    self.tokens &+= batch.count
    self.checksum &+= sum
    return batch.count
  }

  mutating func boolean(_ value: Bool) { self.tokens &+= 1 }
  mutating func null() { self.tokens &+= 1 }

  // A window's events from the windowed path: the same counts and checksum, in one loop. The
  // common kinds are tested first as compares rather than through the switch's jump table,
  // and the subscripts are unchecked: the loop is the whole per-event cost of this sink.
  mutating func events(_ batch: borrowing StreamEventBatch) -> Int {
    let records = batch.records
    var tokens = 0
    var checksum: UInt64 = 0
    var i = 0
    let count = batch.count
    while i < count {
      let record = records[unchecked: i]
      let kind = record.kind
      if kind == .key {
        tokens &+= 1
        checksum &+= batch.bytes(of: i).paddedLeadingWord()
      } else if kind == .string {
        tokens &+= 1
        checksum &+= UInt64(record.length)
      } else if kind == .number {
        tokens &+= 1
        checksum &+= Self.fold(batch.info(of: i))
      } else if kind == .stringChunk {
        checksum &+= UInt64(record.length)
      } else if kind == .endObject || kind == .endArray || kind == .stringEnd {
        // nothing
      } else {
        tokens &+= 1
      }
      i &+= 1
    }
    self.tokens &+= tokens
    self.checksum &+= checksum
    return count
  }
}

// MARK: - Runners

// Shared by every payload-shaped benchmark in the suite, so a chunk size and a buffer capacity
// are both one call away from any of them.
func runFastParser(
  _ payload: [UInt8],
  chunk: Int,
  bufferCapacity: Int = 4_096,
  windowThreshold: Int = .max
) throws -> UInt64 {
  var parser = JSONParser(bufferCapacity: bufferCapacity, windowThreshold: windowThreshold)
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

func runFastParserByteAtATime(_ payload: [UInt8]) throws -> UInt64 {
  var parser = JSONParser()
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

}
