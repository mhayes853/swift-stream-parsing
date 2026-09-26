import Benchmark
import StreamParsing
import StreamParsingBenchmarkModels
import StreamParsingCore

// Each row is an existing in-module row, body for body, over the `public` copy of its model in
// `StreamParsingBenchmarkModels`: the pair isolates what the module boundary costs generated code.
// Registered last so every existing row keeps its batch position.

func crossModuleBenchmarks() {
  // Mirrors `Stream Flat struct - discarding`.
  Benchmark("Stream Flat struct - discarding cross-module") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamDiscarding(Payloads.flat, as: CrossModuleProfile.Partial.self))
    }
  }

  // A model that silently stops matching turns the row into a discard benchmark.
  let twitterFull = expectParses {
    try streamBulkDiscarding(Payloads.twitter, as: CrossModuleTwitterFull.Partial.self)
  }
  precondition(twitterFull.statuses?.count == 100)
  precondition(twitterFull.statuses?[0].user?.screen_name == "ayuu0123")
  addCrossModuleBulkDiscardingRow(
    "Twitter full",
    payload: Payloads.twitter,
    as: CrossModuleTwitterFull.Partial.self
  )
}

// Mirrors the `bulk discarding` row of `addRealWorldConvenienceRows`.
private func addCrossModuleBulkDiscardingRow<Value: StreamParseableRoot>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type
) {
  Benchmark("Real \(name) - bulk discarding cross-module", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try streamBulkDiscarding(payload, as: Value.self) })
    }
  }
}
