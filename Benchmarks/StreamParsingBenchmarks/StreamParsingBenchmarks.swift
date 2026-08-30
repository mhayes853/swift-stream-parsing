import Benchmark
import Foundation
import StreamParsing
import StreamParsingCore

// MARK: - Benchmarks

let payloadMegabytesPerSecond = BenchmarkMetric.custom(
  "Payload MB/s",
  polarity: .prefersLarger,
  useScalingFactor: false
)

let benchmarks: @Sendable () -> Void = {
  // Every payload is a `static let`, so an unloaded one initializes the first time a benchmark
  // reads it — inside a measured region, and for the corpus payloads that means `Bundle.module`
  // and `URL` resource loading counted against the first iteration's wall clock and mallocs.
  // Touching them here moves that to registration. It also stops the suite crashing: three runs
  // died in `NSURL` resource caching and in the runtime's conformance cache, each time in whatever
  // row happened to trip the lazy load, which reads as a parser crash and is not one.
  Payloads.warmUp()
  if ProcessInfo.processInfo.environment["STREAM_PARSING_COLLISION_REPORT"] == "1" {
    reportRealWorldDictionaryCollisions()
  }

  Benchmark.defaultConfiguration = Benchmark.Configuration(
    metrics: [.cpuTotal, .wallClock, .mallocCountTotal, .retainCount, .releaseCount],
    warmupIterations: 3,
    maxDuration: .seconds(3)
  )

  Benchmark("Stream Flat struct - discarding") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamDiscarding(Payloads.flat, as: BenchmarkProfile.Partial.self))
    }
  }

  Benchmark("Stream Long string - discarding") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamDiscarding(Payloads.document, as: BenchmarkDocument.Partial.self))
    }
  }

  Benchmark("Stream Array of structs - snapshot per byte") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamSnapshotting(Payloads.userList, as: BenchmarkUserList.Partial.self))
    }
  }

  Benchmark("Stream Array of structs - discarding") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamDiscarding(Payloads.userList, as: BenchmarkUserList.Partial.self))
    }
  }

  Benchmark("Stream Array of structs - bulk discarding") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamBulkDiscarding(Payloads.userList, as: BenchmarkUserList.Partial.self))
    }
  }

  for chunk in [16, 64, 256, 1024, 4096] {
    Benchmark("Stream Array of structs - snapshot per \(chunk)B chunk") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(
          try streamSnapshottingChunks(
            Payloads.userList,
            chunk: chunk,
            as: BenchmarkUserList.Partial.self
          )
        )
      }
    }

    Benchmark("Stream Array of structs - view read per \(chunk)B chunk") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(
          try streamViewingChunks(
            Payloads.userList,
            chunk: chunk,
            as: BenchmarkUserList.Partial.self
          ) { blackHole($0.total?.value) }
        )
      }
    }
  }

  Benchmark("Stream Array of structs - view read per byte") { benchmark in
    for _ in benchmark.scaledIterations {
      var stream = PartialsStream(
        initialValue: BenchmarkUserList.Partial(),
        from: .json()
      )
      for byte in Payloads.userList {
        try stream.next(byte)
        stream.withView { blackHole($0.total?.value) }
      }
      blackHole(try stream.finish())
    }
  }

  // 100 users is the payload every `Stream Array of structs` row above uses, so its two scaling
  // rows were literal duplicates of them and are gone. These are the other two points.
  for (name, payload) in [
    ("10 users", Payloads.userList10),
    ("400 users", Payloads.userList400)
  ] {
    Benchmark("Scaling \(name) - discarding") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(try streamDiscarding(payload, as: BenchmarkUserList.Partial.self))
      }
    }

    Benchmark("Scaling \(name) - snapshot per byte") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(try streamSnapshotting(payload, as: BenchmarkUserList.Partial.self))
      }
    }
  }

  Benchmark("Scaling 8KB document - snapshot per byte") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamSnapshotting(Payloads.document, as: BenchmarkDocument.Partial.self))
    }
  }

  addFastParserBenchmarks()
  layerOverheadBenchmarks()
  partialSinkReplayBenchmarks()
  parserShapeBenchmarks()
  realWorldBenchmarks()
  stageOneBenchmarks()
  numberKernelBenchmarks()
  streamingAPIBenchmarks()
  retentionBenchmarks()
  dictionaryAllocationBenchmarks()
  homogeneousLeafBenchmarks()
  if #available(macOS 26.0, *) {
    inlineArrayBenchmarks()
    inlineStringBenchmarks()
  }
  keyLookupBenchmarks()
}

// MARK: - Helpers

// A `try?` in a benchmark closure scores an aborted parse as fast, so failures trap instead.
func expectParses<Value>(_ work: () throws -> Value) -> Value {
  do {
    return try work()
  } catch {
    preconditionFailure("Benchmark payload failed to parse: \(error)")
  }
}

func measurePayloadThroughput(
  _ benchmark: Benchmark,
  payload: [UInt8],
  work: () -> Void
) {
  let start = DispatchTime.now().uptimeNanoseconds
  for _ in benchmark.scaledIterations {
    work()
  }
  let elapsed = DispatchTime.now().uptimeNanoseconds - start
  let bytes = Double(payload.count * benchmark.scaledIterations.count)
  let megabytesPerSecond = bytes / Double(elapsed) * 1_000_000_000 / 1_000_000
  benchmark.measurement(payloadMegabytesPerSecond, Int(megabytesPerSecond))
}

func streamDiscarding<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  as type: Value.Type,
  format: JSONStreamFormat = .json()
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: format)
  for byte in bytes {
    try stream.next(byte)
  }
  return try stream.finish()
}

func streamDiscardingChunks<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  chunk: Int,
  as type: Value.Type,
  format: JSONStreamFormat = .json()
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: format)
  var index = bytes.startIndex
  while index < bytes.endIndex {
    let end = bytes.index(index, offsetBy: chunk, limitedBy: bytes.endIndex) ?? bytes.endIndex
    try stream.next(bytes[index..<end])
    index = end
  }
  return try stream.finish()
}

func streamSnapshotting<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  as type: Value.Type
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
  for byte in bytes {
    try stream.next(byte)
    blackHole(stream.current)
  }
  return try stream.finish()
}

func streamSnapshottingChunks<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  chunk: Int,
  as type: Value.Type
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
  var index = bytes.startIndex
  while index < bytes.endIndex {
    let end = bytes.index(index, offsetBy: chunk, limitedBy: bytes.endIndex) ?? bytes.endIndex
    try stream.next(bytes[index..<end])
    blackHole(stream.current)
    index = end
  }
  return try stream.finish()
}

func streamViewingChunks<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  chunk: Int,
  as type: Value.Type,
  read: (borrowing Value.View) -> Void
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
  var index = bytes.startIndex
  while index < bytes.endIndex {
    let end = bytes.index(index, offsetBy: chunk, limitedBy: bytes.endIndex) ?? bytes.endIndex
    try stream.next(bytes[index..<end])
    stream.withView { read($0) }
    index = end
  }
  return try stream.finish()
}

func streamBulkDiscarding<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  as type: Value.Type,
  format: JSONStreamFormat = .json()
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: format)
  try stream.next(bytes)
  return try stream.finish()
}
