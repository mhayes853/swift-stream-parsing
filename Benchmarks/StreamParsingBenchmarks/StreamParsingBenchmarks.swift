import Benchmark
import StreamParsing

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
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
          ) { blackHole($0.total) }
        )
      }
    }
  }

  Benchmark("Stream Array of structs - view read per byte") { benchmark in
    for _ in benchmark.scaledIterations {
      var stream = PartialsStream(
        initialValue: BenchmarkUserList.Partial(), from: .json()
      )
      for byte in Payloads.userList {
        try stream.next(byte)
        stream.withView { blackHole($0.total) }
      }
      blackHole(try stream.finish())
    }
  }

  Benchmark("Stream Array of structs - snapshot read per byte") { benchmark in
    for _ in benchmark.scaledIterations {
      var stream = PartialsStream(
        initialValue: BenchmarkUserList.Partial(), from: .json()
      )
      for byte in Payloads.userList {
        try stream.next(byte)
        blackHole(stream.current.total)
      }
      blackHole(try stream.finish())
    }
  }

  addFastParserBenchmarks()
}

// MARK: - Helpers

private func streamDiscarding<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  as type: Value.Type
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
  for byte in bytes {
    try stream.next(byte)
  }
  return try stream.finish()
}

private func streamSnapshotting<Value: StreamParseableRoot>(
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

private func streamSnapshottingChunks<Value: StreamParseableRoot>(
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

private func streamViewingChunks<Value: StreamParseableRoot>(
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

private func streamBulkDiscarding<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  as type: Value.Type
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
  try stream.next(bytes)
  return try stream.finish()
}
