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
//   qwen3 calls      small and medium Hermes-style tool arguments, including nested source edits
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
  ("Qwen 3 search tool call", Payloads.qwen3SearchToolCall),
  ("Qwen 3 workspace edit tool call", Payloads.qwen3WorkspaceEditToolCall),
  ("Qwen 3 structured response", Payloads.qwen3StructuredResponse),
  ("Mesh", Payloads.mesh)
]

// Mirrors each fast-layer real-world row through the convenience layer. The models deliberately
// retain the corpus's characteristic values rather than merely reproducing its container spine.
private func addRealWorldConvenienceRows<Value: StreamParseableRoot>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type,
  includeByteByByte: Bool = false,
  includeReusedStream: Bool = false
) {
  Benchmark("Real \(name) - bulk discarding", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try streamBulkDiscarding(payload, as: Value.self) })
    }
  }

  // The amortized variant: one stream, re-armed by `finishValue(resettingTo:)` between
  // documents. Deliberately NOT a row the library's headline numbers come from — the canonical
  // rows measure from-scratch parsing, allocations included. This one exists for the payloads
  // small enough that per-parse setup dominates (tool calls), where the agent-loop caller
  // reuses one stream against one schema.
  if includeReusedStream {
    Benchmark(
      "Real \(name) - bulk discarding, reused stream", configuration: payloadConfiguration
    ) { benchmark in
      var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(
          expectParses {
            try stream.next(payload)
            return try stream.finishValue(resettingTo: Value.streamInitialValue())
          }
        )
      }
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

  // The same convenience-layer parse through the windowed path, which is where number batches
  // reach `PartialSink`. The row above is its gate-off control.
  Benchmark("Real \(name) - bulk discarding windowed", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(
        expectParses {
          try streamBulkDiscarding(payload, as: Value.self, format: .json(windowThreshold: 1))
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

private func validateRealWorldModels() {
  // A model that silently stops matching turns a convenience benchmark into a discard benchmark.
  // Validate every root once during registration, outside every measured region.
  let twitter = expectParses {
    try streamBulkDiscarding(Payloads.twitter, as: BenchmarkTwitterMatched.Partial.self)
  }
  precondition(twitter.statuses?.count == 100)
  precondition(twitter.statuses?[0].user?.screen_name == "ayuu0123")
  let citm = expectParses {
    try streamBulkDiscarding(Payloads.citmCatalog, as: BenchmarkCITM.Partial.self)
  }
  precondition(citm.areaNames?.count == 17)
  precondition(citm.seatCategoryNames?.count == 64)
  precondition(citm.events?.count == 184)
  precondition(citm.performances?.count == 243)
  let llm = expectParses {
    try streamBulkDiscarding(Payloads.llmMessage, as: BenchmarkLLMMessage.Partial.self)
  }
  precondition(llm.content?.count == 636)
  precondition(llm.content?.lazy.filter { $0.type == "tool_use" }.count == 90)
  precondition(llm.stop_reason == "end_turn")
  let canada = expectParses {
    try streamBulkDiscarding(Payloads.canada, as: BenchmarkCanada.Partial.self)
  }
  precondition(canada.features?.count == 1)
  precondition(canada.features?[0].geometry?.coordinates?.count == 480)
  let canadaDynamic = expectParses {
    try streamBulkDiscarding(Payloads.canada, as: BenchmarkCanadaDynamic.Partial.self)
  }
  precondition(canadaDynamic.features?.count == 1)
  precondition(canadaDynamic.features?[0].geometry?.coordinates?.count == 480)
  let hintedCanada = expectParses {
    try streamBulkDiscarding(Payloads.canada, as: BenchmarkCanadaCapacityHint.Partial.self)
  }
  precondition(hintedCanada.features?.count == 1)
  precondition(hintedCanada.features?[0].geometry?.coordinates?.count == 480)
  let canadaStreamInitialValue = expectParses {
    try streamBulkDiscarding(
      Payloads.canada, as: BenchmarkCanadaStreamInitialValue.Partial.self
    )
  }
  precondition(canadaStreamInitialValue.features.count == 1)
  precondition(canadaStreamInitialValue.features[0].geometry.coordinates.count == 480)
  let gsoc = expectParses {
    try streamBulkDiscarding(
      Payloads.gsoc2018,
      as: StreamDictionary<BenchmarkGSoCProject.Partial>.self
    )
  }
  precondition(gsoc.count == 1_264)
  precondition(gsoc["0"]?.description?.isEmpty == false)
  let longDescriptions = gsoc.lazy.filter {
    ($0.value.description?.utf8Count ?? 0) > 64
  }
  precondition(longDescriptions.count == 1_236)
  let hintedGSoC = expectParses {
    try streamBulkDiscarding(
      Payloads.gsoc2018,
      as: StreamDictionary<BenchmarkGSoCProjectStringCapacity.Partial>.self
    )
  }
  precondition(hintedGSoC.count == 1_264)
  precondition(hintedGSoC["0"]?.description?.isEmpty == false)
  let mesh = expectParses {
    try streamBulkDiscarding(Payloads.mesh, as: BenchmarkMesh.Partial.self)
  }
  precondition(mesh.positions?.count == 10_800)
  precondition(mesh.normals?.count == 10_800)
  precondition(mesh.indices?.count == 33_408)
  precondition(mesh.colors?.count == 3_600)
  precondition(mesh.batches?.count == 1)
  let meshDynamic = expectParses {
    try streamBulkDiscarding(Payloads.mesh, as: BenchmarkMeshDynamic.Partial.self)
  }
  precondition(meshDynamic.influences?.count == 3_600)
  let hintedMesh = expectParses {
    try streamBulkDiscarding(Payloads.mesh, as: BenchmarkMeshCapacityHint.Partial.self)
  }
  precondition(hintedMesh.positions?.count == 10_800)
  precondition(hintedMesh.normals?.count == 10_800)
  precondition(hintedMesh.indices?.count == 33_408)
  precondition(hintedMesh.colors?.count == 3_600)
  precondition(hintedMesh.batches?.count == 1)
  let github = expectParses {
    try streamBulkDiscarding(
      Payloads.githubEvents,
      as: StreamArray<BenchmarkGitHubEvent.Partial>.self
    )
  }
  precondition(github.count == 30)
  precondition(github[0].actor?.login?.isEmpty == false)
  let qwenSearch = expectParses {
    try streamBulkDiscarding(
      Payloads.qwen3SearchToolCall,
      as: BenchmarkQwen3ToolCall.Partial.self
    )
  }
  precondition(qwenSearch.name == "search_code")
  precondition(qwenSearch.arguments?.include?.count == 12)
  precondition(qwenSearch.arguments?.context?.languages?.count == 4)
  let qwenEdit = expectParses {
    try streamBulkDiscarding(
      Payloads.qwen3WorkspaceEditToolCall,
      as: BenchmarkQwen3ToolCall.Partial.self
    )
  }
  precondition(qwenEdit.name == "apply_workspace_edits")
  precondition(qwenEdit.arguments?.edits?.count == 96)
  precondition(qwenEdit.arguments?.edits?[0].replacement?.isEmpty == false)
  let qwenStructured = expectParses {
    try streamBulkDiscarding(
      Payloads.qwen3StructuredResponse,
      as: BenchmarkQwen3StructuredResponse.Partial.self
    )
  }
  precondition(qwenStructured.findings?.count == 36)
  precondition(qwenStructured.recommendation?.steps?.count == 5)
}

private func addRealWorldFastRows() {
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

    // The same two feeds through the windowed path (JSONParserWindow.swift), which the gate
    // takes for any chunk at or above the threshold. Both variants live in one binary so they
    // can be interleaved in one run.
    Benchmark("Real \(name) - bulk windowed", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max, windowThreshold: 1) })
      }
    }

    Benchmark("Real \(name) - 16KB chunks windowed", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: 16_384, windowThreshold: 1) })
      }
    }
  }

  // Byte by byte on the two documents whose content is hardest for the resume path — every
  // non-ASCII byte in `twitterescaped` arrives as a six byte `\u` escape — rather than on all
  // payload, where it would measure the same per-byte state machine repeatedly.
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
}

private func addAllRealWorldConvenienceRows() {
  addRealWorldBaselineConvenienceRows()
  addRealWorldCapacityConvenienceRows()
}

private func addRealWorldBaselineConvenienceRows() {
  addRealWorldConvenienceRows(
    "Twitter",
    payload: Payloads.twitter,
    as: BenchmarkTwitterMatched.Partial.self
  )
  addRealWorldConvenienceRows(
    "Twitter escaped",
    payload: Payloads.twitterEscaped,
    as: BenchmarkTwitterMatched.Partial.self,
    includeByteByByte: true
  )
  addRealWorldConvenienceRows(
    "Twitter full",
    payload: Payloads.twitter,
    as: BenchmarkTwitterFull.Partial.self
  )
  addRealWorldConvenienceRows(
    "Canada",
    payload: Payloads.canada,
    as: BenchmarkCanada.Partial.self
  )
  addRealWorldConvenienceRows(
    "Canada dynamic coordinates",
    payload: Payloads.canada,
    as: BenchmarkCanadaDynamic.Partial.self
  )
  addRealWorldConvenienceRows(
    "Canada streamInitialValue",
    payload: Payloads.canada,
    as: BenchmarkCanadaStreamInitialValue.Partial.self
  )
  addRealWorldConvenienceRows(
    "CITM catalog",
    payload: Payloads.citmCatalog,
    as: BenchmarkCITM.Partial.self
  )
  addRealWorldConvenienceRows(
    "GSoC 2018",
    payload: Payloads.gsoc2018,
    as: StreamDictionary<BenchmarkGSoCProject.Partial>.self
  )
  addRealWorldConvenienceRows(
    "GitHub events",
    payload: Payloads.githubEvents,
    as: StreamArray<BenchmarkGitHubEvent.Partial>.self
  )
  addRealWorldConvenienceRows(
    "LLM message",
    payload: Payloads.llmMessage,
    as: BenchmarkLLMMessage.Partial.self,
    includeByteByByte: true
  )
  addRealWorldConvenienceRows(
    "Qwen 3 search tool call",
    payload: Payloads.qwen3SearchToolCall,
    as: BenchmarkQwen3ToolCall.Partial.self,
    includeByteByByte: true,
    includeReusedStream: true
  )
  addRealWorldConvenienceRows(
    "Qwen 3 workspace edit tool call",
    payload: Payloads.qwen3WorkspaceEditToolCall,
    as: BenchmarkQwen3ToolCall.Partial.self,
    includeByteByByte: true,
    includeReusedStream: true
  )
  addRealWorldConvenienceRows(
    "Qwen 3 structured response",
    payload: Payloads.qwen3StructuredResponse,
    as: BenchmarkQwen3StructuredResponse.Partial.self,
    includeByteByByte: true,
    includeReusedStream: true
  )
  addRealWorldConvenienceRows(
    "Mesh",
    payload: Payloads.mesh,
    as: BenchmarkMesh.Partial.self
  )
  addRealWorldConvenienceRows(
    "Mesh dynamic influences",
    payload: Payloads.mesh,
    as: BenchmarkMeshDynamic.Partial.self
  )
}

private func addRealWorldCapacityConvenienceRows() {
  addRealWorldConvenienceRows(
    "Canada capacity hint",
    payload: Payloads.canada,
    as: BenchmarkCanadaCapacityHint.Partial.self
  )
  addRealWorldConvenienceRows(
    "GSoC 2018 string capacity hint",
    payload: Payloads.gsoc2018,
    as: StreamDictionary<BenchmarkGSoCProjectStringCapacity.Partial>.self
  )
  addRealWorldConvenienceRows(
    "LLM message string capacity hint",
    payload: Payloads.llmMessage,
    as: BenchmarkLLMMessageStringCapacity.Partial.self,
    includeByteByByte: true
  )
  addRealWorldConvenienceRows(
    "Mesh capacity hint",
    payload: Payloads.mesh,
    as: BenchmarkMeshCapacityHint.Partial.self
  )
}

private func addRealWorldViewRows() {
  for chunk in [1_400, 16_384, 65_536] {
    addRealWorldViewRows(for: chunk)
    addRealWorldStringCapacityViewRows(for: chunk)
  }
}

private func addRealWorldViewRows(for chunk: Int) {
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
          ) { blackHole($0.stop_reason?.value) }
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

private func addRealWorldStringCapacityViewRows(for chunk: Int) {
  Benchmark(
    "Real LLM message string capacity hint - view read per \(chunk)B chunk",
    configuration: payloadConfiguration
  ) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.llmMessage) {
      blackHole(
        expectParses {
          try streamViewingChunks(
            Payloads.llmMessage,
            chunk: chunk,
            as: BenchmarkLLMMessageStringCapacity.Partial.self
          ) { blackHole($0.stop_reason?.value) }
        }
      )
    }
  }

  Benchmark(
    "Real LLM message string capacity hint - snapshot per \(chunk)B chunk",
    configuration: payloadConfiguration
  ) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.llmMessage) {
      blackHole(
        expectParses {
          try streamSnapshottingChunks(
            Payloads.llmMessage,
            chunk: chunk,
            as: BenchmarkLLMMessageStringCapacity.Partial.self
          )
        }
      )
    }
  }
}

func realWorldBenchmarks() {
  validateRealWorldModels()
  addRealWorldFastRows()
  addAllRealWorldConvenienceRows()
  addRealWorldCodableRows()
  addRealWorldViewRows()
}
