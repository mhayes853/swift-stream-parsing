import Benchmark
import StreamParsing

// MARK: - Parseable enum models

@StreamParseable
enum BenchmarkStringEnum: String, Equatable {
  @StreamParseableDefault
  case unknown
  case queued
  case running
  case finished
}

@StreamParseable
enum BenchmarkIntegerEnum: Int, Equatable {
  @StreamParseableDefault
  case unknown = -1
  case queued = 0
  case running = 1
  case finished = 2
}

@StreamParseable
enum BenchmarkObjectEnum: Equatable {
  @StreamParseableDefault
  case unknown
  case queued
  case running
  case finished
}

@StreamParseable
struct BenchmarkEnumText: Equatable {
  var body: String = ""
}

@StreamParseable
enum BenchmarkAssociatedEnum: Equatable {
  @StreamParseableDefault
  case unknown
  case text(BenchmarkEnumText)
  case retry(attempts: Int, reason: String)
}

@StreamParseable
struct BenchmarkStringEnumDocument: Equatable {
  var values: [BenchmarkStringEnum] = []
}

@StreamParseable
struct BenchmarkIntegerEnumDocument: Equatable {
  var values: [BenchmarkIntegerEnum] = []
}

@StreamParseable
struct BenchmarkObjectEnumDocument: Equatable {
  var values: [BenchmarkObjectEnum] = []
}

@StreamParseable
struct BenchmarkAssociatedEnumDocument: Equatable {
  var values: [BenchmarkAssociatedEnum] = []
}

// The payloads keep the enum case distribution mixed so conversion cannot specialize to one
// case. They are generated before registration, outside every measured region.
enum EnumBenchmarkPayloads {
  static let string = makeArray(count: 20_000) { index in
    let value: String
    switch index % 4 {
    case 0: value = "queued"
    case 1: value = "running"
    case 2: value = "finished"
    default: value = "unknown"
    }
    return "\"\(value)\""
  }

  static let integer = makeArray(count: 20_000) { index in
    "\(index % 4 - 1)"
  }

  static let object = makeArray(count: 20_000) { index in
    let key: String
    switch index % 4 {
    case 0: key = "queued"
    case 1: key = "running"
    case 2: key = "finished"
    default: key = "unknown"
    }
    return "{\"\(key)\":{}}"
  }

  static let associated = makeArray(count: 20_000) { index in
    switch index % 3 {
    case 0:
      return "{\"text\":{\"_0\":{\"body\":\"message_\(index)\"}}}"
    case 1:
      return "{\"retry\":{\"attempts\":\(index % 8),\"reason\":\"transient_\(index)\"}}"
    default:
      return "{\"unknown\":{}}"
    }
  }

  private static func makeArray(count: Int, _ element: (Int) -> String) -> [UInt8] {
    Array("{\"values\":[\((0..<count).map(element).joined(separator: ","))]}".utf8)
  }
}

// The parser produces a partial document. Running the generated total conversion afterwards is
// intentional: it exercises the enum's raw-value/object discriminator and, for the associated
// form, its generated payload conversion as well.
private func parseEnumPayload<Value: StreamParseable>(
  _ payload: [UInt8], as type: Value.Type
) throws -> Value {
  let partial = try streamBulkDiscarding(payload, as: Value.Partial.self)
  return Value.streamValueOrInitial(from: partial)
}

private func parseEnumPayloadByteByByte<Value: StreamParseable>(
  _ payload: [UInt8], as type: Value.Type
) throws -> Value {
  let partial = try streamDiscarding(payload, as: Value.Partial.self)
  return Value.streamValueOrInitial(from: partial)
}

private func addEnumBenchmark<Value: StreamParseable>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type
) {
  Benchmark("Parseable enum \(name) - bulk", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try parseEnumPayload(payload, as: Value.self) })
    }
  }

  Benchmark(
    "Parseable enum \(name) - byte by byte",
    configuration: payloadConfiguration
  ) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try parseEnumPayloadByteByByte(payload, as: Value.self) })
    }
  }
}

private func validateEnumBenchmarks() {
  let strings = expectParses {
    try parseEnumPayload(EnumBenchmarkPayloads.string, as: BenchmarkStringEnumDocument.self)
  }
  precondition(strings.values.count == 20_000 && strings.values[1] == .running)

  let integers = expectParses {
    try parseEnumPayload(EnumBenchmarkPayloads.integer, as: BenchmarkIntegerEnumDocument.self)
  }
  precondition(integers.values.count == 20_000 && integers.values[2] == .running)

  let objects = expectParses {
    try parseEnumPayload(EnumBenchmarkPayloads.object, as: BenchmarkObjectEnumDocument.self)
  }
  precondition(objects.values.count == 20_000 && objects.values[3] == .unknown)

  let associated = expectParses {
    try parseEnumPayload(
      EnumBenchmarkPayloads.associated,
      as: BenchmarkAssociatedEnumDocument.self
    )
  }
  precondition(associated.values.count == 20_000)
  if case .retry(let attempts, let reason) = associated.values[1] {
    precondition(attempts == 1 && reason == "transient_1")
  } else {
    preconditionFailure("associated enum benchmark payload resolved to the wrong case")
  }
}

func enumBenchmarks() {
  validateEnumBenchmarks()

  addEnumBenchmark(
    "String raw value", payload: EnumBenchmarkPayloads.string,
    as: BenchmarkStringEnumDocument.self
  )
  addEnumBenchmark(
    "Integer raw value", payload: EnumBenchmarkPayloads.integer,
    as: BenchmarkIntegerEnumDocument.self
  )
  addEnumBenchmark(
    "Raw-less object", payload: EnumBenchmarkPayloads.object,
    as: BenchmarkObjectEnumDocument.self
  )
  addEnumBenchmark(
    "Associated values", payload: EnumBenchmarkPayloads.associated,
    as: BenchmarkAssociatedEnumDocument.self
  )
}
