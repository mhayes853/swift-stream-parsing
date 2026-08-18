import Benchmark
import StreamParsing
import StreamParsingCore

// Shapes the suite had no coverage of at all: nesting depth, schema member count, buffer
// capacity, chunk boundaries that land inside tokens, and number tokens measured inside a
// document rather than in a bare corpus.

// MARK: - Depth

// Depth is capped at 64 by the container bitmask and every level pushes and pops a frame, but
// nothing else in the suite nests past three, so the frame spine was entirely unmeasured. These
// payloads are tiny, so the per-level cost is what the numbers are for — throughput here is
// noise. `JSONParserBufferTests` and `ErrorOffsetTests` pin the behaviour at the cap.
private func depthBenchmarks() {
  let payloads: [(String, [UInt8])] = [
    ("objects 16", Payloads.deepObjects16),
    ("objects 63", Payloads.deepObjects63),
    ("arrays 63", Payloads.deepArrays63),
  ]

  for (name, payload) in payloads {
    Benchmark("Depth \(name) - bulk") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(expectParses { try runFastParser(payload, chunk: .max) })
      }
    }

    Benchmark("Depth \(name) - byte by byte") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(expectParses { try runFastParserByteAtATime(payload) })
      }
    }
  }
}

// MARK: - Schema width

// Key matching scans precomputed leading words, so its cost is in the member count of the type
// being parsed into. Every other model in the suite declares six members or fewer; `BenchmarkWide`
// declares forty-eight. Hitting the first member, the last, and a key the schema does not declare
// gives the two ends of the scan and the discard path.
private func schemaWidthBenchmarks() {
  let cases: [(String, [UInt8])] = [
    ("first member", Payloads.wideFirst),
    ("last member", Payloads.wideLast),
    ("undeclared key", Payloads.wideMiss),
  ]

  for (name, payload) in cases {
    Benchmark("Schema 48 members - \(name)") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(expectParses { try streamBulkDiscarding(payload, as: BenchmarkWideRows.Partial.self) })
      }
    }
  }

  // The same payloads through the raw sink, which does no key matching at all, so the schema's
  // share of the convenience layer figure above is the difference between the two.
  Benchmark("Schema 48 members - sink only") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(expectParses { try runFastParser(Payloads.wideLast, chunk: .max) })
    }
  }
}

// MARK: - Buffer capacity

// The parser's buffer holds the longest single token — a key, a number, or an escaped string run.
// `bufferCapacity` defaults to 4096 and was never swept, and the caller-supplied initializer that
// avoids the parser's own malloc appeared exactly once in the suite, hardcoded at 256. A capacity
// below the longest token fails with `bufferExhausted`, so the sweep starts above it.
private func bufferCapacityBenchmarks() {
  var configuration = Benchmark.defaultConfiguration
  configuration.metrics = [.wallClock, .cpuTotal, .mallocCountTotal]

  for capacity in [64, 256, 4_096, 65_536] {
    Benchmark("Buffer \(capacity)B - array of structs", configuration: configuration) { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(
          expectParses {
            try runFastParser(Payloads.userList, chunk: 64, bufferCapacity: capacity)
          }
        )
      }
    }
  }

  // Long keys are the token that actually needs the room, so this is where a capacity too small
  // to hold one would show up as a throw rather than as a slowdown.
  for capacity in [64, 4_096] {
    Benchmark("Buffer \(capacity)B - long keys", configuration: configuration) { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(
          expectParses {
            try runFastParser(Payloads.countsLongKeys, chunk: 64, bufferCapacity: capacity)
          }
        )
      }
    }
  }

  // The malloc the allocating initializer pays per parser, which the doc names as what dominates
  // a small payload. The supplied-buffer row is the same parse without it.
  Benchmark("Buffer allocating - flat struct", configuration: configuration) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(expectParses { try runFastParser(Payloads.flat, chunk: .max) })
    }
  }

  Benchmark("Buffer supplied - flat struct", configuration: configuration) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { buffer in
          expectParses {
            var parser = JSONParser(buffer: buffer)
            var sink = FastCountingSink()
            try Payloads.flat.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
            try parser.finish(into: &sink)
            return sink.checksum
          }
        }
      )
    }
  }
}

// MARK: - Chunk boundaries

// Every other chunked benchmark feeds power-of-two chunks, which land inside a token only by
// accident. These sizes are chosen to land inside one nearly every time: 3 bytes cannot hold a
// four-byte UTF-8 sequence or a `\uXXXX` escape, and 7 and 13 are coprime with everything the
// generators emit, so the split walks through each token across the payload. The resume path is
// what the library is, and this is its worst case.
private func chunkBoundaryBenchmarks() {
  let payloads: [(String, [UInt8])] = [
    ("escaped string", Payloads.escapedString),
    ("unicode escaped", Payloads.unicodeEscapedString),
    ("non-ASCII", Payloads.nonASCIIString),
    ("array of structs", Payloads.userList),
    ("large integers", Payloads.largeIntegers),
  ]

  for (name, payload) in payloads {
    for chunk in [3, 7, 13] {
      Benchmark("Boundary \(name) - \(chunk)B chunks", configuration: payloadConfiguration) { benchmark in
        measurePayloadThroughput(benchmark, payload: payload) {
          blackHole(expectParses { try runFastParser(payload, chunk: chunk) })
        }
      }
    }
  }
}

// MARK: - Numbers in situ

// The number path was only ever measured by a bank of private re-implementations parsing bare
// comma-separated corpora, none of which called the shipped scanners; that file is gone. These
// measure the same token shapes through the real parser. `large integers` is the 17-19 digit run
// the eight-digit block was chosen for — a document id — and `floats` is what `canada.json` is
// made of, so the synthetic and real-world rows can be read against each other.
private func numberBenchmarks() {
  let payloads: [(String, [UInt8])] = [
    ("large integers", Payloads.largeIntegers),
    ("floats", Payloads.floats),
    ("small integers", Payloads.matrix),
  ]

  for (name, payload) in payloads {
    Benchmark("Numbers \(name) - bulk", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max) })
      }
    }

    Benchmark("Numbers \(name) - byte by byte", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParserByteAtATime(payload) })
      }
    }

    // Number grammar validation is one of the three checks `.unchecked` turns off, and this is
    // the payload shape where it has the most to do.
    Benchmark("Numbers \(name) - bulk unchecked", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max, configuration: .unchecked) })
      }
    }
  }

  // Through the convenience layer, where each token is also converted into a member.
  Benchmark("Numbers large integers - discarding") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(
        expectParses {
          try streamBulkDiscarding(Payloads.largeIntegers, as: BenchmarkIntegers.Partial.self)
        }
      )
    }
  }

  Benchmark("Numbers floats - discarding") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(
        expectParses { try streamBulkDiscarding(Payloads.floats, as: BenchmarkFloats.Partial.self) }
      )
    }
  }
}

// MARK: - Container field entry

// `PartialSink` resolves a container field's destination through `StreamSchema.enterField`, which
// runs once per container *occurrence* rather than once per type. Every other model in the suite
// declares its containers on the root, so that call happens once per document and its cost is
// invisible. `BenchmarkEntryList` declares three of them on a repeated element instead, which is
// what a real response looks like, and enters container fields 600 times per document.
//
// The sink row is the same payload through `FastCountingSink`, which has no schema at all, so the
// difference between the two is what routing through one costs on this shape.
private func containerFieldBenchmarks() {
  Benchmark("Fields per element - bulk discarding", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.entryList) {
      blackHole(
        expectParses {
          try streamBulkDiscarding(Payloads.entryList, as: BenchmarkEntryList.Partial.self)
        }
      )
    }
  }

  Benchmark("Fields per element - sink only", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.entryList) {
      blackHole(expectParses { try runFastParser(Payloads.entryList, chunk: .max) })
    }
  }

  // The same payload into the aliased model, whose container fields the macro cannot identify
  // from syntax. That entry resolves through `StreamContainerPartial` with a hoisted schema
  // constant; before the hoist it built a fresh schema per container occurrence, and the malloc
  // column against the row above is where that shows.
  Benchmark(
    "Fields per element - bulk discarding, aliased",
    configuration: payloadConfiguration
  ) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.entryList) {
      blackHole(
        expectParses {
          try streamBulkDiscarding(Payloads.entryList, as: BenchmarkAliasedEntryList.Partial.self)
        }
      )
    }
  }
}

func parserShapeBenchmarks() {
  depthBenchmarks()
  schemaWidthBenchmarks()
  containerFieldBenchmarks()
  bufferCapacityBenchmarks()
  chunkBoundaryBenchmarks()
  numberBenchmarks()
}
