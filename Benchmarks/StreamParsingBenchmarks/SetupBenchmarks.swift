import Benchmark
import StreamParsing

// Per-stream setup, the one place a schema is read outside a schema build: `PartialsStream.init`
// reads `Value.streamSchema` once. The real-world rows parse kilobytes per stream, so a change to
// that read is invisible there; these isolate it. `StreamArray<Int>` has always been read through
// the schema cache, so its row is the control for the others.
private let emptyObject = Array("{}".utf8)

func setupBenchmarks() {
  Benchmark("Setup Flat struct - schema read") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(BenchmarkProfile.Partial.streamSchema)
    }
  }

  Benchmark("Setup StreamArray<Int> - schema read") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(StreamArray<Int>.streamSchema)
    }
  }

  Benchmark("Setup Flat struct - empty object stream") { benchmark in
    for _ in benchmark.scaledIterations {
      var stream = PartialsStream(initialValue: BenchmarkProfile.Partial(), from: .json())
      blackHole(
        expectParses {
          try stream.next(emptyObject)
          return try stream.finish()
        }
      )
    }
  }
}
