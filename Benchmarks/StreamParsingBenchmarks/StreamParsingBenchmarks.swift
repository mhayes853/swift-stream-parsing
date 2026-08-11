import Benchmark
import StreamParsing

// MARK: - Helpers

/// Feeds the whole payload to the parser in a single call.
///
/// This measures the best case where the parser can amortize writes across a chunk.
private func parseBulk<Value: StreamParseableValue>(
  _ bytes: [UInt8],
  as type: Value.Type
) throws -> Value {
  var parser = JSONStreamParser<Value>()
  parser.registerHandlers()
  var value = Value.initialParseableValue()
  try parser.parse(bytes: bytes, into: &value)
  try parser.finish(reducer: &value)
  return value
}

/// Feeds the payload to the parser one byte at a time.
///
/// This is the worst case the library supports, where every byte forces a write into the
/// value being built up.
private func parseByteByByte<Value: StreamParseableValue>(
  _ bytes: [UInt8],
  as type: Value.Type
) throws -> Value {
  var parser = JSONStreamParser<Value>()
  parser.registerHandlers()
  var value = Value.initialParseableValue()
  for byte in bytes {
    try parser.parse(bytes: CollectionOfOne(byte), into: &value)
  }
  try parser.finish(reducer: &value)
  return value
}

/// Drives a ``PartialsStream`` byte by byte, observing every intermediate partial.
private func streamPartials<Value: StreamParseableValue>(
  _ bytes: [UInt8],
  as type: Value.Type
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.initialParseableValue(), from: .json())
  for byte in bytes {
    blackHole(try stream.next(byte))
  }
  return try stream.finish()
}

private func addBenchmarks<Value: StreamParseableValue>(
  named name: String,
  payload: [UInt8],
  as type: Value.Type,
  includePartialsStream: Bool = false
) {
  Benchmark("\(name) - bulk") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try parseBulk(payload, as: Value.self))
    }
  }

  Benchmark("\(name) - byte by byte") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try parseByteByByte(payload, as: Value.self))
    }
  }

  // Every parse benchmark pays for handler registration once, so measure it on its own to keep
  // the parse numbers interpretable for the smaller payloads.
  Benchmark("\(name) - handler registration") { benchmark in
    for _ in benchmark.scaledIterations {
      var parser = JSONStreamParser<Value>()
      parser.registerHandlers()
      blackHole(parser)
    }
  }

  guard includePartialsStream else { return }

  Benchmark("\(name) - partials stream") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamPartials(payload, as: Value.self))
    }
  }
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
  Benchmark.defaultConfiguration = Benchmark.Configuration(
    metrics: [.cpuTotal, .wallClock, .mallocCountTotal, .retainCount, .releaseCount],
    warmupIterations: 3,
    maxDuration: .seconds(3)
  )

  addBenchmarks(
    named: "Flat struct",
    payload: Payloads.flat,
    as: BenchmarkProfile.Partial.self,
    includePartialsStream: true
  )
  addBenchmarks(
    named: "Nested structs",
    payload: Payloads.nested,
    as: BenchmarkEmployee.Partial.self
  )
  addBenchmarks(
    named: "Array of structs",
    payload: Payloads.userList,
    as: BenchmarkUserList.Partial.self,
    includePartialsStream: true
  )
  addBenchmarks(
    named: "Nested arrays",
    payload: Payloads.matrix,
    as: BenchmarkMatrix.Partial.self
  )
  addBenchmarks(
    named: "Dictionary",
    payload: Payloads.counts,
    as: BenchmarkCounts.Partial.self
  )
  addBenchmarks(
    named: "Long string",
    payload: Payloads.document,
    as: BenchmarkDocument.Partial.self
  )
  // Parses the document payload into a type whose keys do not match, so no handler is ever
  // resolved. Isolates the parser state machine from the cost of accumulating values.
  addBenchmarks(
    named: "Long string unhandled",
    payload: Payloads.document,
    as: BenchmarkCounts.Partial.self
  )
  addBenchmarks(
    named: "Long string 4KB",
    payload: Payloads.documentHalf,
    as: BenchmarkDocument.Partial.self
  )
  addBenchmarks(
    named: "Long string 16KB",
    payload: Payloads.documentDouble,
    as: BenchmarkDocument.Partial.self
  )
}
