import Benchmark
import StreamParsing
import StreamParsingCore

// What the convenience layer costs, measured against the parse it sits on.
//
// Every other row in the suite measures one tier: `Fast ...` drives a counting sink, `Stream ...`
// and `Real ... discarding` drive a `PartialsStream`, and the two sets do not agree on payloads,
// chunk sizes or models, so no pair of them subtracts. These do: one payload, one chunking, one
// configuration, four sinks, so the difference between two rows is the tier and nothing else.
//
//   null sink      the parser with its events thrown away — the floor a sink is measured against
//   counting sink  `FastCountingSink`, the sink every `Fast ...` row uses: a token count, a span
//                  length, and one padded word per key
//   partial sink   `JSONParser` + `PartialSink` directly, routing every token into a real value
//   stream         `PartialsStream`, which is `PartialSink` plus the wrapper's owned storage,
//                  throw latch and `Sequence` entry point
//
// partial sink − counting sink is what routing a token into a value costs. stream − partial sink
// is what the wrapper around it costs. Both are only readable against null sink, which says how
// much of the wall clock was ever the parse.

// MARK: - Null sink

// Conforms and does nothing. The collapsed `key` and `string` are overridden, as every serious
// sink overrides them, so the floor is not measuring three calls where a sink would take one.
struct NullSink: StreamParseSink {
  var streamFailure: StreamSinkFailure? { nil }

  mutating func beginObject() {}
  mutating func endObject() {}
  mutating func beginArray() {}
  mutating func endArray() {}

  mutating func key(_ bytes: Span<UInt8>) {}
  mutating func keyBegin() {}
  mutating func keyChunk(_ bytes: Span<UInt8>) {}
  mutating func keyEnd() {}

  mutating func string(_ bytes: Span<UInt8>) {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {}
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}

// MARK: - Feeding

enum LayerFeed {
  case bulk
  case chunks(Int)
  case byteByByte

  var name: String {
    switch self {
    case .bulk: "bulk"
    case .chunks(let size) where size >= 1_024: "\(size / 1_024)KB chunks"
    case .chunks(let size): "\(size)B chunks"
    case .byteByByte: "byte by byte"
    }
  }
}

// One feeding loop for the two sink tiers, so a chunk boundary falls in the same place for both.
private func feed<Sink: StreamParseSink & ~Copyable>(
  _ payload: [UInt8],
  _ mode: LayerFeed,
  into sink: inout Sink
) throws {
  var parser = JSONParser(bufferCapacity: 4_096)
  switch mode {
  case .byteByByte:
    for byte in payload {
      try parser.parse(byte: byte, into: &sink)
    }
  case .bulk, .chunks:
    let size = if case .chunks(let size) = mode { size } else { Int.max }
    try payload.withUnsafeBufferPointer { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = min(size, buffer.count - offset)
        let slice = UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: count)
        try parser.parse(slice, into: &sink)
        offset += count
      }
    }
  }
  try parser.finish(into: &sink)
}

func runLayerNullSink(_ payload: [UInt8], _ mode: LayerFeed) throws {
  var sink = NullSink()
  try feed(payload, mode, into: &sink)
  blackHole(sink.streamFailure)
}

func runLayerCountingSink(_ payload: [UInt8], _ mode: LayerFeed) throws -> UInt64 {
  var sink = FastCountingSink()
  try feed(payload, mode, into: &sink)
  return sink.checksum
}

// `PartialSink` without the stream around it: the same allocated root storage a `PartialsStream`
// owns, but fed from the parser directly, so the wrapper's per call cost is not in this row.
func runLayerPartialSink<Value: StreamParseableRoot>(
  _ payload: [UInt8],
  _ mode: LayerFeed,
  as type: Value.Type
) throws {
  let storage = UnsafeMutablePointer<Value>.allocate(capacity: 1)
  storage.initialize(to: Value.streamInitialValue())
  defer {
    storage.deinitialize(count: 1)
    storage.deallocate()
  }
  var sink = PartialSink(root: storage)
  try feed(payload, mode, into: &sink)
  blackHole(storage.pointee)
}

func runLayerStream<Value: StreamParseableRoot>(
  _ payload: [UInt8],
  _ mode: LayerFeed,
  as type: Value.Type
) throws {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
  switch mode {
  case .byteByByte:
    for byte in payload {
      try stream.next(byte)
    }
  case .bulk:
    try stream.next(payload)
  case .chunks(let size):
    var index = payload.startIndex
    while index < payload.endIndex {
      let end = payload.index(index, offsetBy: size, limitedBy: payload.endIndex)
        ?? payload.endIndex
      try stream.next(payload[index..<end])
      index = end
    }
  }
  blackHole(try stream.finish())
}

// MARK: - Registration

private func addLayerRows<Value: StreamParseableRoot>(
  _ name: String,
  _ payload: [UInt8],
  as type: Value.Type,
  modes: [LayerFeed]
) {
  for mode in modes {
    Benchmark("Layer \(name) \(mode.name) - null sink", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runLayerNullSink(payload, mode) })
      }
    }

    Benchmark("Layer \(name) \(mode.name) - counting sink", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runLayerCountingSink(payload, mode) })
      }
    }

    Benchmark("Layer \(name) \(mode.name) - partial sink", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runLayerPartialSink(payload, mode, as: Value.self) })
      }
    }

    Benchmark("Layer \(name) \(mode.name) - stream", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runLayerStream(payload, mode, as: Value.self) })
      }
    }
  }
}

// Where the partial sink's time goes: routing, or the values themselves.
//
// The structure model has the same containers as the matched one and no scalar key that matches,
// so both rows enter every container, append every element and match every key, and only the
// matched row writes a value. The pair is bulk only, because a difference between two sinks does
// not need to be measured at three chunk sizes to be read.
private func addValueMaterializationRows<Value: StreamParseableRoot>(
  _ name: String,
  _ payload: [UInt8],
  structureOnly type: Value.Type
) {
  Benchmark("Layer \(name) bulk - partial sink, no values", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try runLayerPartialSink(payload, .bulk, as: Value.self) })
    }
  }
}

func layerOverheadBenchmarks() {
  // Small payloads carry a byte by byte row, where the per call cost of a tier is a larger share
  // of the total than anywhere else. The two large ones carry a 16 KB row instead, which is the
  // granularity they would actually arrive at, and `LLM message` carries both because it is the
  // document the convenience layer exists for.
  addLayerRows(
    "Flat struct", Payloads.flat, as: BenchmarkProfile.Partial.self,
    modes: [.bulk, .byteByByte]
  )
  addLayerRows(
    "Array of structs", Payloads.userList, as: BenchmarkUserList.Partial.self,
    modes: [.bulk, .chunks(64), .byteByByte]
  )
  addLayerRows(
    "Long string", Payloads.document, as: BenchmarkDocument.Partial.self,
    modes: [.bulk, .byteByByte]
  )
  addLayerRows(
    "Dictionary", Payloads.counts, as: BenchmarkCounts.Partial.self,
    modes: [.bulk, .byteByByte]
  )
  addLayerRows(
    "Twitter", Payloads.twitter, as: BenchmarkTwitterMatched.Partial.self,
    modes: [.bulk, .chunks(16_384)]
  )
  addLayerRows(
    "LLM message", Payloads.llmMessage, as: BenchmarkLLMMessage.Partial.self,
    modes: [.bulk, .chunks(16_384), .byteByByte]
  )

  addValueMaterializationRows(
    "Twitter", Payloads.twitter, structureOnly: BenchmarkTwitterStructure.Partial.self
  )
  addValueMaterializationRows(
    "LLM message", Payloads.llmMessage, structureOnly: BenchmarkLLMMessageStructure.Partial.self
  )
}
