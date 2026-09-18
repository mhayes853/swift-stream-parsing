import Benchmark
import Foundation
import StreamParsing

// Public streaming APIs on the payloads they are meant to serve. The real-world discarding rows
// already cover PartialsStream's bulk, 16 KB and byte-fed throughput; these add the practical
// smaller chunk sizes and make the cost of observing a view or retaining a snapshot explicit.

private struct ImmediateAsyncChunks: AsyncSequence, Sendable {
  typealias Element = [UInt8]

  let chunks: [[UInt8]]

  struct AsyncIterator: AsyncIteratorProtocol {
    let chunks: [[UInt8]]
    var index = 0

    mutating func next() async -> [UInt8]? {
      guard self.index < self.chunks.count else { return nil }
      defer { self.index += 1 }
      return self.chunks[self.index]
    }
  }

  func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(chunks: self.chunks)
  }
}

private func chunks(_ payload: [UInt8], size: Int) -> [[UInt8]] {
  var result = [[UInt8]]()
  result.reserveCapacity((payload.count + size - 1) / size)
  var index = payload.startIndex
  while index < payload.endIndex {
    let end = payload.index(index, offsetBy: size, limitedBy: payload.endIndex) ?? payload.endIndex
    result.append(Array(payload[index..<end]))
    index = end
  }
  return result
}

private func consumeAsyncPartials<Value: StreamParseableRoot & Sendable>(
  _ chunks: [[UInt8]],
  as type: Value.Type
) async throws -> Int {
  let source = ImmediateAsyncChunks(chunks: chunks)
  let partials = source.partials(of: Value.self, from: .json())
  var emitted = 0
  for try await partial in partials {
    blackHole(partial)
    emitted += 1
  }
  return emitted
}

private func expectParsesAsync<Value>(_ work: () async throws -> Value) async -> Value {
  do {
    return try await work()
  } catch {
    preconditionFailure("Benchmark payload failed to parse: \(error)")
  }
}

private func measurePayloadThroughputAsync(
  _ benchmark: Benchmark,
  payload: [UInt8],
  work: () async -> Void
) async {
  let start = DispatchTime.now().uptimeNanoseconds
  for _ in benchmark.scaledIterations {
    await work()
  }
  let elapsed = DispatchTime.now().uptimeNanoseconds - start
  let bytes = Double(payload.count * benchmark.scaledIterations.count)
  let megabytesPerSecond = bytes / Double(elapsed) * 1_000_000_000 / 1_000_000
  benchmark.measurement(payloadMegabytesPerSecond, Int(megabytesPerSecond))
}

private func addPartialsStreamRows<Value: StreamParseableRoot>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type,
  chunkSizes: [Int],
  read: @escaping (borrowing Value.View) -> Void
) {
  for chunk in chunkSizes {
    let input = chunks(payload, size: chunk)
    Benchmark(
      "API PartialIterator \(name) - \(chunk)B chunks",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        expectParses {
          var iterator = input.partialIterator(of: Value.self, from: .json())
          while let update = try iterator.next() { blackHole(update) }
        }
      }
    }
    Benchmark(
      "API ScopedViews \(name) - \(chunk)B chunks",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        expectParses {
          try input.withPartialViews(of: Value.self, from: .json()) { view, final in
            read(view)
            blackHole(final)
          }
        }
      }
    }
    Benchmark(
      "API PartialsStream \(name) - discard per \(chunk)B chunk",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(
          expectParses { try streamDiscardingChunks(payload, chunk: chunk, as: Value.self) }
        )
      }
    }

    Benchmark(
      "API PartialsStream \(name) - view per \(chunk)B chunk",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(
          expectParses {
            try streamViewingChunks(payload, chunk: chunk, as: Value.self, read: read)
          }
        )
      }
    }

    Benchmark(
      "API PartialsStream \(name) - snapshot per \(chunk)B chunk",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(
          expectParses { try streamSnapshottingChunks(payload, chunk: chunk, as: Value.self) }
        )
      }
    }
  }
}

private func addAsyncSequenceRows<Value: StreamParseableRoot & Sendable>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type,
  chunkSizes: [Int],
  project: @escaping @Sendable (borrowing Value.View) -> StreamString?,
  field: ObservedFieldPath<Value, StreamString>
) {
  for chunkSize in chunkSizes {
    let input = chunks(payload, size: chunkSize)
    Benchmark(
      "API ObservedField \(name) - \(chunkSize)B chunks",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        expectParses {
          var iterator = try input.partialIterator(of: Value.self, from: .json())
            .observeField(field).removeDuplicateUpdates()
          while let update = try iterator.next() { blackHole(update) }
        }
      }
    }
    Benchmark(
      "API AsyncObservedField \(name) - \(chunkSize)B chunks",
      configuration: payloadConfiguration
    ) { benchmark in
      await measurePayloadThroughputAsync(benchmark, payload: payload) {
        await expectParsesAsync {
          for try await update in ImmediateAsyncChunks(chunks: input)
            .partials(of: Value.self, from: .json()).observeField(field).removeDuplicateUpdates()
          {
            blackHole(update)
          }
        }
      }
    }
    Benchmark(
      "API Projected \(name) - \(chunkSize)B chunks",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        expectParses {
          var iterator = input.partialIterator(of: Value.self, from: .json())
            .project(project).removeDuplicateUpdates()
          while let update = try iterator.next() { blackHole(update) }
        }
      }
    }
    Benchmark(
      "API AsyncProjected \(name) - \(chunkSize)B chunks",
      configuration: payloadConfiguration
    ) { benchmark in
      await measurePayloadThroughputAsync(benchmark, payload: payload) {
        await expectParsesAsync {
          for try await update in ImmediateAsyncChunks(chunks: input)
            .partials(of: Value.self, from: .json()).project(project).removeDuplicateUpdates()
          {
            blackHole(update)
          }
        }
      }
    }
    Benchmark(
      "API AsyncSequence \(name) - \(chunkSize)B chunks",
      configuration: payloadConfiguration
    ) { benchmark in
      await measurePayloadThroughputAsync(benchmark, payload: payload) {
        blackHole(
          await expectParsesAsync {
            try await consumeAsyncPartials(input, as: Value.self)
          }
        )
      }
    }
  }
}

func streamingAPIBenchmarks() {
  addPartialsStreamRows(
    "Qwen 3 search tool call",
    payload: Payloads.qwen3SearchToolCall,
    as: BenchmarkQwen3ToolCall.Partial.self,
    chunkSizes: [16, 64, 256]
  ) { blackHole($0.name?.value) }
  addAsyncSequenceRows(
    "Qwen 3 search tool call",
    payload: Payloads.qwen3SearchToolCall,
    as: BenchmarkQwen3ToolCall.Partial.self,
    chunkSizes: [16, 64, 256],
    project: { $0.name?.value },
    field: expectParses { try ObservedFieldPath(\BenchmarkQwen3ToolCall.Partial.name) }
  )

  addPartialsStreamRows(
    "Qwen 3 workspace edit tool call",
    payload: Payloads.qwen3WorkspaceEditToolCall,
    as: BenchmarkQwen3ToolCall.Partial.self,
    chunkSizes: [64, 1_400, 16_384]
  ) { blackHole($0.name?.value) }
  addAsyncSequenceRows(
    "Qwen 3 workspace edit tool call",
    payload: Payloads.qwen3WorkspaceEditToolCall,
    as: BenchmarkQwen3ToolCall.Partial.self,
    chunkSizes: [64, 1_400, 16_384],
    project: { $0.name?.value },
    field: expectParses { try ObservedFieldPath(\BenchmarkQwen3ToolCall.Partial.name) }
  )

  addPartialsStreamRows(
    "Qwen 3 structured response",
    payload: Payloads.qwen3StructuredResponse,
    as: BenchmarkQwen3StructuredResponse.Partial.self,
    chunkSizes: [64, 1_400, 16_384]
  ) { blackHole($0.summary?.value) }
  addAsyncSequenceRows(
    "Qwen 3 structured response",
    payload: Payloads.qwen3StructuredResponse,
    as: BenchmarkQwen3StructuredResponse.Partial.self,
    chunkSizes: [64, 1_400, 16_384],
    project: { $0.summary?.value },
    field: expectParses { try ObservedFieldPath(\BenchmarkQwen3StructuredResponse.Partial.summary) }
  )
  addCompletedConversionRows("Qwen 3 search tool call", payload: Payloads.qwen3SearchToolCall,
    plain: BenchmarkQwen3ToolCall.Partial.self, converted: ConvertedToolCall.Partial.self)
  addCompletedConversionRows("Qwen 3 workspace edit tool call", payload: Payloads.qwen3WorkspaceEditToolCall,
    plain: BenchmarkQwen3ToolCall.Partial.self, converted: ConvertedToolCall.Partial.self)
  addCompletedConversionRows("Qwen 3 structured response", payload: Payloads.qwen3StructuredResponse,
    plain: BenchmarkQwen3StructuredResponse.Partial.self, converted: ConvertedStructuredResponse.Partial.self)

}


private enum CompletedString: StreamCompletedValueConversion {
  typealias Source = StreamString
  static func convertToValue(_ source: borrowing Source.View) -> String { String(source.value) }
  static func convertFromValue(_ value: String) -> StreamString { StreamString(value) }
}

@StreamParseable
private struct ConvertedToolCall {
  @StreamParseableMember(completedConversion: CompletedString.self)
  var name: String = ""
  var arguments: BenchmarkQwen3ToolArguments = BenchmarkQwen3ToolArguments()
}

@StreamParseable
private struct ConvertedStructuredResponse {
  @StreamParseableMember(completedConversion: CompletedString.self)
  var summary: String = ""
  var findings: [BenchmarkQwen3Finding] = []
  var recommendation: BenchmarkQwen3Recommendation = BenchmarkQwen3Recommendation()
}

private func addCompletedConversionRows<Plain: StreamParseableRoot, Converted: StreamParseableRoot>(
  _ name: String, payload: [UInt8], plain: Plain.Type, converted: Converted.Type
) {
  let input = chunks(payload, size: 64)
  func add<Value: StreamParseableRoot>(_ mode: String, _ type: Value.Type) {
    Benchmark("Conversion \(mode) \(name) - 64B chunks", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        expectParses {
          var stream = PartialsStream<Value>(from: .json())
          for chunk in input {
            try stream.next(chunk)
            blackHole(stream.current)
          }
          blackHole(try stream.finish())
        }
      }
    }
  }
  add("source", plain)
  add("completed", converted)
}
