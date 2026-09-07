import Benchmark
import Foundation

// Foundation's decoder consumes Data rather than a byte span. Constructing that Data is kept
// outside the timed region, just as payload loading is warmed before registration; the measured
// work is JSONDecoder initialization, parsing, and full model materialization.
private func addFoundationRealWorldRow<Value: Decodable>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type
) {
  let data = Data(payload)
  do {
    _ = try JSONDecoder().decode(Value.self, from: data)
  } catch {
    preconditionFailure("Foundation model failed to decode \(name): \(error)")
  }

  Benchmark("Real \(name) - JSONDecoder", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      do {
        blackHole(try JSONDecoder().decode(Value.self, from: data))
      } catch {
        preconditionFailure("Foundation model failed to decode \(name): \(error)")
      }
    }
  }
}

func foundationRealWorldBenchmarks() {
  addFoundationRealWorldRow(
    "Twitter",
    payload: Payloads.twitter,
    as: CodableTwitterMatched.self
  )
  addFoundationRealWorldRow(
    "Twitter escaped",
    payload: Payloads.twitterEscaped,
    as: CodableTwitterMatched.self
  )
  addFoundationRealWorldRow(
    "Twitter full",
    payload: Payloads.twitter,
    as: CodableTwitterFull.self
  )
  addFoundationRealWorldRow("Canada", payload: Payloads.canada, as: CodableCanada.self)
  addFoundationRealWorldRow(
    "CITM catalog",
    payload: Payloads.citmCatalog,
    as: CodableCITM.self
  )
  addFoundationRealWorldRow(
    "GSoC 2018",
    payload: Payloads.gsoc2018,
    as: [String: CodableGSoCProject].self
  )
  addFoundationRealWorldRow(
    "GitHub events",
    payload: Payloads.githubEvents,
    as: [CodableGitHubEvent].self
  )
  addFoundationRealWorldRow(
    "LLM message",
    payload: Payloads.llmMessage,
    as: CodableLLMMessage.self
  )
  addFoundationRealWorldRow(
    "Qwen 3 search tool call",
    payload: Payloads.qwen3SearchToolCall,
    as: CodableQwen3ToolCall.self
  )
  addFoundationRealWorldRow(
    "Qwen 3 workspace edit tool call",
    payload: Payloads.qwen3WorkspaceEditToolCall,
    as: CodableQwen3ToolCall.self
  )
  addFoundationRealWorldRow(
    "Qwen 3 structured response",
    payload: Payloads.qwen3StructuredResponse,
    as: CodableQwen3StructuredResponse.self
  )
  addFoundationRealWorldRow("Mesh", payload: Payloads.mesh, as: CodableMesh.self)
}
