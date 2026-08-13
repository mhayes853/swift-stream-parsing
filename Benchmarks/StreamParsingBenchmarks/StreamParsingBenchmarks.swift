import Benchmark
import StreamParsing

// These measure the convenience layer: PartialsStream driven a byte at a time, which is what an
// application consuming a model as it streams actually does. The parser itself is measured in
// FastParserBenchmarks, against a sink that only counts.
//
// The registration based parser these used to compare against is gone, and with it the handler
// registration benchmark: there are no handlers to register.

// MARK: - Helpers

/// Drives the stream byte by byte and never asks for a state, which is the floor: no snapshot,
/// no view, just the parse.
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

/// Takes a whole snapshot after every byte, which is what `partials()` does.
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

  // The cost of keeping every state, against the cost of keeping none. This is the difference
  // the view layer exists to let a caller avoid, and the reason `next()` stops returning a value.
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

  // Reading one member per byte through a view, against snapshotting the whole value to read the
  // same member. Both observe every intermediate state; only one copies the containers to do it.
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
