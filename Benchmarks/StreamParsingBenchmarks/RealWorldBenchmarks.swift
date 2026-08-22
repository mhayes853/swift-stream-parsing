import Benchmark
import StreamParsing
import StreamParsingCore

// Real datasets, not shapes chosen to isolate a code path.
//
// `twitter.json` was the only one of these for a long time, and it is the friendly member of its
// corpus. The rest of `yyjson_benchmark`'s set is here now because each covers something the
// synthetic payloads only approximate, and because it is the corpus every comparable parser
// publishes against, so these numbers can be read next to somebody else's.
//
//   canada           float-heavy geometry, ~2.1 MB — coordinate pairs and almost nothing else
//   citm_catalog     deep nesting and heavily repeated keys, ~1.6 MB
//   gsoc-2018        large with long string values, ~3.2 MB
//   twitterescaped   the same document as twitter with every non-ASCII byte as a \u escape
//   github_events    a small API response, ~64 KB
//   llm_message      an assistant message: long escaped markdown, tool-use objects, small ints
//
// Three of these are larger than any cache level the parse runs in, which nothing else in the
// suite was. Validation is unconditional now, so there is no configuration axis here any more —
// these rows measure the parser as it ships.

private let realWorldPayloads: [(String, [UInt8])] = [
  ("Twitter", Payloads.twitter),
  ("Twitter escaped", Payloads.twitterEscaped),
  ("Canada", Payloads.canada),
  ("CITM catalog", Payloads.citmCatalog),
  ("GSoC 2018", Payloads.gsoc2018),
  ("GitHub events", Payloads.githubEvents),
  ("LLM message", Payloads.llmMessage),
  ("Mesh", Payloads.mesh),
]

// Mirrors each fast-layer real-world row through the convenience layer. The models deliberately
// retain the corpus's characteristic values rather than merely reproducing its container spine.
private func addRealWorldConvenienceRows<Value: StreamParseableRoot>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type,
  includeByteByByte: Bool = false
) {
  Benchmark("Real \(name) - bulk discarding", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try streamBulkDiscarding(payload, as: Value.self) })
    }
  }

  Benchmark("Real \(name) - 16KB chunks discarding", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(
        expectParses {
          try streamDiscardingChunks(payload, chunk: 16_384, as: Value.self)
        }
      )
    }
  }

  if includeByteByByte {
    Benchmark("Real \(name) - byte by byte discarding", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try streamDiscarding(payload, as: Value.self) })
      }
    }
  }
}

func realWorldBenchmarks() {
  // A model that silently stops matching turns a convenience benchmark into a discard benchmark.
  // Validate the new roots once during registration, outside every measured region.
  let canada = expectParses {
    try streamBulkDiscarding(Payloads.canada, as: BenchmarkCanada.Partial.self)
  }
  precondition(canada.features?.count == 1)
  precondition(canada.features?[0].geometry?.coordinates?.count == 480)
  let gsoc = expectParses {
    try streamBulkDiscarding(
      Payloads.gsoc2018, as: StreamDictionary<BenchmarkGSoCProject.Partial>.self
    )
  }
  precondition(gsoc.count == 1_264)
  precondition(gsoc["0"]?.description?.isEmpty == false)
  let longDescriptions = gsoc.lazy.filter {
    ($0.value.description?.utf8Count ?? 0) > 64
  }
  precondition(longDescriptions.count == 1_236)
  let mesh = expectParses {
    try streamBulkDiscarding(Payloads.mesh, as: BenchmarkMesh.Partial.self)
  }
  precondition(mesh.positions?.count == 10_800)
  precondition(mesh.normals?.count == 10_800)
  precondition(mesh.indices?.count == 33_408)
  precondition(mesh.colors?.count == 3_600)
  precondition(mesh.batches?.count == 1)
  let github = expectParses {
    try streamBulkDiscarding(
      Payloads.githubEvents, as: StreamArray<BenchmarkGitHubEvent.Partial>.self
    )
  }
  precondition(github.count == 30)
  precondition(github[0].actor?.login?.isEmpty == false)

  for (name, payload) in realWorldPayloads {
    Benchmark("Real \(name) - bulk", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max) })
      }
    }

    // 16 KB is a TLS record, which is the granularity a document this size actually arrives at.
    Benchmark("Real \(name) - 16KB chunks", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: 16_384) })
      }
    }
  }

  // Byte by byte on the two documents whose content is hardest for the resume path — every
  // non-ASCII byte in `twitterescaped` arrives as a six byte `\u` escape — rather than on all
  // seven, where it would measure the same per-byte state machine seven times.
  for (name, payload) in [
    ("Twitter escaped", Payloads.twitterEscaped),
    ("LLM message", Payloads.llmMessage)
  ] {
    Benchmark("Real \(name) - byte by byte", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParserByteAtATime(payload) })
      }
    }
  }

  addRealWorldConvenienceRows(
    "Twitter", payload: Payloads.twitter, as: BenchmarkTwitterMatched.Partial.self
  )
  addRealWorldConvenienceRows(
    "Twitter escaped", payload: Payloads.twitterEscaped,
    as: BenchmarkTwitterMatched.Partial.self, includeByteByByte: true
  )
  addRealWorldConvenienceRows(
    "Canada", payload: Payloads.canada, as: BenchmarkCanada.Partial.self
  )
  addRealWorldConvenienceRows(
    "CITM catalog", payload: Payloads.citmCatalog, as: BenchmarkCITM.Partial.self
  )
  addRealWorldConvenienceRows(
    "GSoC 2018", payload: Payloads.gsoc2018,
    as: StreamDictionary<BenchmarkGSoCProject.Partial>.self
  )
  addRealWorldConvenienceRows(
    "GitHub events", payload: Payloads.githubEvents,
    as: StreamArray<BenchmarkGitHubEvent.Partial>.self
  )
  addRealWorldConvenienceRows(
    "LLM message", payload: Payloads.llmMessage,
    as: BenchmarkLLMMessage.Partial.self, includeByteByByte: true
  )
  addRealWorldConvenienceRows(
    "Mesh", payload: Payloads.mesh, as: BenchmarkMesh.Partial.self
  )

  for chunk in [1_400, 16_384, 65_536] {
    Benchmark(
      "Real LLM message - view read per \(chunk)B chunk",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: Payloads.llmMessage) {
        blackHole(
          expectParses {
            try streamViewingChunks(
              Payloads.llmMessage,
              chunk: chunk,
              as: BenchmarkLLMMessage.Partial.self
            ) { blackHole($0.stop_reason) }
          }
        )
      }
    }

    Benchmark(
      "Real LLM message - snapshot per \(chunk)B chunk",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: Payloads.llmMessage) {
        blackHole(
          expectParses {
            try streamSnapshottingChunks(
              Payloads.llmMessage,
              chunk: chunk,
              as: BenchmarkLLMMessage.Partial.self
            )
          }
        )
      }
    }
  }

  // Keep the old mismatched model as an explicit diagnostic. The parity row above uses the model
  // whose snake_case fields actually match the payload.
  Benchmark(
    "Real Twitter - bulk discarding, unmatched keys",
    configuration: payloadConfiguration
  ) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.twitter) {
      blackHole(
        expectParses {
          try streamBulkDiscarding(Payloads.twitter, as: BenchmarkTwitter.Partial.self)
        }
      )
    }
  }
}
