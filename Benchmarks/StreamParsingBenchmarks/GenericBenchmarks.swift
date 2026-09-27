import Benchmark
import StreamParsing
import StreamParsingBenchmarkModels
import StreamParsingCore

// Generic models against their concrete twins, body for body. Registered after everything else so
// every existing row keeps its batch position.
//
// - `Twitter generic` / `Twitter`: every leaf of the matched model behind a parameter, each still
//   classified to the kind the concrete overloads pick. The pair should be at parity.
// - `Twitter generic custom text` / `Twitter custom text`: the text members are a string the table
//   has no layout for, so the concrete model applies them through the parent's closures (`custom`)
//   and the generic one through their own schema (`delegated`).
// - The cross-module pair: the same, across the module boundary a library user's model sits behind.
// - `Twitter snake strategy` / `Twitter custom strategy` / `Twitter`: camelCase members whose keys
//   a key decoding strategy derives, during expansion and when the schema is built. The tables are
//   the same, so all three should be at parity.

func genericBenchmarks() {
  let generic = expectParses {
    try streamBulkDiscarding(Payloads.twitter, as: BenchmarkTwitterGeneric.Partial.self)
  }
  precondition(generic.statuses?.count == 100)
  precondition(generic.statuses?[0].user?.screen_name == "ayuu0123")
  let customText = expectParses {
    try streamBulkDiscarding(Payloads.twitter, as: BenchmarkTwitterCustomText.Partial.self)
  }
  precondition(customText.statuses?[0].user?.screen_name?.storage == "ayuu0123")
  let genericCustomText = expectParses {
    try streamBulkDiscarding(Payloads.twitter, as: BenchmarkTwitterGenericCustomText.Partial.self)
  }
  precondition(genericCustomText.statuses?[0].user?.screen_name?.storage == "ayuu0123")
  let crossModule = expectParses {
    try streamBulkDiscarding(Payloads.twitter, as: CrossModuleTwitterGeneric.Partial.self)
  }
  precondition(crossModule.statuses?[0].user?.screen_name == "ayuu0123")
  let snakeStrategy = expectParses {
    try streamBulkDiscarding(Payloads.twitter, as: BenchmarkTwitterSnakeStrategy.Partial.self)
  }
  precondition(snakeStrategy.statuses?[0].user?.screenName == "ayuu0123")
  precondition(snakeStrategy.statuses?[0].user?.followersCount != nil)
  let customStrategy = expectParses {
    try streamBulkDiscarding(Payloads.twitter, as: BenchmarkTwitterCustomStrategy.Partial.self)
  }
  precondition(customStrategy.statuses?[0].user?.screenName == "ayuu0123")
  precondition(customStrategy.statuses?[0].user?.followersCount != nil)

  addGenericBulkDiscardingRow("Twitter generic", as: BenchmarkTwitterGeneric.Partial.self)
  addGenericBulkDiscardingRow("Twitter custom text", as: BenchmarkTwitterCustomText.Partial.self)
  addGenericBulkDiscardingRow(
    "Twitter generic custom text", as: BenchmarkTwitterGenericCustomText.Partial.self
  )
  addGenericBulkDiscardingRow(
    "Twitter matched cross-module", as: CrossModuleTwitterMatched.Partial.self
  )
  addGenericBulkDiscardingRow(
    "Twitter generic cross-module", as: CrossModuleTwitterGeneric.Partial.self
  )
  addGenericBulkDiscardingRow(
    "Twitter snake strategy", as: BenchmarkTwitterSnakeStrategy.Partial.self
  )
  addGenericBulkDiscardingRow(
    "Twitter custom strategy", as: BenchmarkTwitterCustomStrategy.Partial.self
  )
}

// Mirrors the `bulk discarding` row of `addRealWorldConvenienceRows`.
private func addGenericBulkDiscardingRow<Value: StreamParseableRoot>(
  _ name: String,
  as type: Value.Type
) {
  Benchmark("Real \(name) - bulk discarding", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.twitter) {
      blackHole(expectParses { try streamBulkDiscarding(Payloads.twitter, as: Value.self) })
    }
  }
}
