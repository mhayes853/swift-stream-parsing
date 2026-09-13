import Foundation
import Benchmark
import YYJSON

// The stream parser models intentionally default absent members because an incomplete stream is
// valid input. Codable synthesis does not use those defaults when a key is absent, so the few
// heterogeneous real-world objects below get the same default-on-missing behavior explicitly.
private extension KeyedDecodingContainer {
  func decodeDefault<T: Decodable>(_ type: T.Type, forKey key: Key, default value: T) throws -> T {
    try decodeIfPresent(type, forKey: key) ?? value
  }
}

extension BenchmarkGSoCProject {
  private enum CodingKeys: String, CodingKey {
    case name, description, sponsor, author
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      name: try container.decodeDefault(String.self, forKey: .name, default: ""),
      description: try container.decodeDefault(String.self, forKey: .description, default: ""),
      sponsor: try container.decodeDefault(
        BenchmarkGSoCOrganization.self, forKey: .sponsor, default: .init()
      ),
      author: try container.decodeDefault(
        BenchmarkGSoCOrganization.self, forKey: .author, default: .init()
      )
    )
  }
}

extension BenchmarkGSoCOrganization {
  private enum CodingKeys: String, CodingKey {
    case name, disambiguatingDescription, description, url, logo
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      name: try container.decodeDefault(String.self, forKey: .name, default: ""),
      disambiguatingDescription: try container.decodeDefault(
        String.self, forKey: .disambiguatingDescription, default: ""
      ),
      description: try container.decodeDefault(String.self, forKey: .description, default: ""),
      url: try container.decodeDefault(String.self, forKey: .url, default: ""),
      logo: try container.decodeDefault(String.self, forKey: .logo, default: "")
    )
  }
}

extension BenchmarkGitHubPayload {
  private enum CodingKeys: String, CodingKey {
    case commits, distinct_size, ref, push_id, head, before, size
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      commits: try container.decodeDefault(
        [BenchmarkGitHubCommit].self, forKey: .commits, default: []
      ),
      distinct_size: try container.decodeDefault(Int.self, forKey: .distinct_size, default: 0),
      ref: try container.decodeDefault(String.self, forKey: .ref, default: ""),
      push_id: try container.decodeDefault(Int.self, forKey: .push_id, default: 0),
      head: try container.decodeDefault(String.self, forKey: .head, default: ""),
      before: try container.decodeDefault(String.self, forKey: .before, default: ""),
      size: try container.decodeDefault(Int.self, forKey: .size, default: 0)
    )
  }
}

extension BenchmarkContentBlock {
  private enum CodingKeys: String, CodingKey {
    case type, text, name
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      type: try container.decodeDefault(String.self, forKey: .type, default: ""),
      text: try container.decodeDefault(String.self, forKey: .text, default: ""),
      name: try container.decodeDefault(String.self, forKey: .name, default: "")
    )
  }
}

extension BenchmarkQwen3ToolArguments {
  private enum CodingKeys: String, CodingKey {
    case query, path, include, exclude, case_sensitive, max_results, context, edits
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      query: try container.decodeDefault(String.self, forKey: .query, default: ""),
      path: try container.decodeDefault(String.self, forKey: .path, default: ""),
      include: try container.decodeDefault([String].self, forKey: .include, default: []),
      exclude: try container.decodeDefault([String].self, forKey: .exclude, default: []),
      case_sensitive: try container.decodeDefault(
        Bool.self, forKey: .case_sensitive, default: false
      ),
      max_results: try container.decodeDefault(Int.self, forKey: .max_results, default: 0),
      context: try container.decodeDefault(
        BenchmarkQwen3SearchContext.self, forKey: .context, default: .init()
      ),
      edits: try container.decodeDefault(
        [BenchmarkQwen3WorkspaceEdit].self, forKey: .edits, default: []
      )
    )
  }
}

private struct CodableRealWorldRow<Value: Decodable> {
  let name: String
  let payload: [UInt8]
  let type: Value.Type
}

private func decodeWithFoundation<Value: Decodable>(
  _ data: Data,
  as type: Value.Type,
  decoder: JSONDecoder
) throws -> Value {
  try decoder.decode(type, from: data)
}

private func decodeWithYYJSON<Value: Decodable>(
  _ data: Data,
  as type: Value.Type,
  decoder: YYJSONDecoder
) throws -> Value {
  try decoder.decode(type, from: data)
}

private func addCodableRows<Value: Decodable>(_ row: CodableRealWorldRow<Value>) {
  let data = Data(row.payload)
  let foundationDecoder = JSONDecoder()
  let yyjsonDecoder = YYJSONDecoder()
  // Keep both decoders on their lossless/default number strategies. The typed models, rather
  // than a DOM or raw byte checksum, are the value being measured.

  Benchmark("Real \(row.name) - JSONDecoder Codable", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: row.payload) {
      blackHole(expectParses {
        try decodeWithFoundation(data, as: row.type, decoder: foundationDecoder)
      })
    }
  }

  Benchmark("Real \(row.name) - swift-yyjson Codable", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: row.payload) {
      blackHole(expectParses {
        try decodeWithYYJSON(data, as: row.type, decoder: yyjsonDecoder)
      })
    }
  }
}

private func validateCodableRealWorldModels() {
  let foundation = JSONDecoder()
  let yyjson = YYJSONDecoder()

  func check<Value: Decodable>(_ row: CodableRealWorldRow<Value>) {
    let data = Data(row.payload)
    blackHole(expectParses { try decodeWithFoundation(data, as: row.type, decoder: foundation) })
    blackHole(expectParses { try decodeWithYYJSON(data, as: row.type, decoder: yyjson) })
  }

  check(CodableRealWorldRow(
    name: "Twitter", payload: Payloads.twitter, type: BenchmarkTwitterMatched.self
  ))
  check(CodableRealWorldRow(
    name: "Twitter escaped", payload: Payloads.twitterEscaped, type: BenchmarkTwitterMatched.self
  ))
  check(CodableRealWorldRow(
    name: "Canada", payload: Payloads.canada, type: BenchmarkCanada.self
  ))
  check(CodableRealWorldRow(
    name: "CITM catalog", payload: Payloads.citmCatalog, type: BenchmarkCITM.self
  ))
  check(CodableRealWorldRow(
    name: "GSoC 2018", payload: Payloads.gsoc2018, type: [String: BenchmarkGSoCProject].self
  ))
  check(CodableRealWorldRow(
    name: "GitHub events", payload: Payloads.githubEvents, type: [BenchmarkGitHubEvent].self
  ))
  check(CodableRealWorldRow(
    name: "LLM message", payload: Payloads.llmMessage, type: BenchmarkLLMMessage.self
  ))
  check(CodableRealWorldRow(
    name: "Qwen 3 search tool call",
    payload: Payloads.qwen3SearchToolCall,
    type: BenchmarkQwen3ToolCall.self
  ))
  check(CodableRealWorldRow(
    name: "Qwen 3 workspace edit tool call",
    payload: Payloads.qwen3WorkspaceEditToolCall,
    type: BenchmarkQwen3ToolCall.self
  ))
  check(CodableRealWorldRow(
    name: "Qwen 3 structured response",
    payload: Payloads.qwen3StructuredResponse,
    type: BenchmarkQwen3StructuredResponse.self
  ))
  check(CodableRealWorldRow(
    name: "Mesh", payload: Payloads.mesh, type: BenchmarkMesh.self
  ))
}

func addRealWorldCodableRows() {
  validateCodableRealWorldModels()

  addCodableRows(CodableRealWorldRow(
    name: "Twitter", payload: Payloads.twitter, type: BenchmarkTwitterMatched.self
  ))
  addCodableRows(CodableRealWorldRow(
    name: "Twitter escaped", payload: Payloads.twitterEscaped, type: BenchmarkTwitterMatched.self
  ))
  addCodableRows(CodableRealWorldRow(
    name: "Canada", payload: Payloads.canada, type: BenchmarkCanada.self
  ))
  addCodableRows(CodableRealWorldRow(
    name: "CITM catalog", payload: Payloads.citmCatalog, type: BenchmarkCITM.self
  ))
  addCodableRows(CodableRealWorldRow(
    name: "GSoC 2018", payload: Payloads.gsoc2018, type: [String: BenchmarkGSoCProject].self
  ))
  addCodableRows(CodableRealWorldRow(
    name: "GitHub events", payload: Payloads.githubEvents, type: [BenchmarkGitHubEvent].self
  ))
  addCodableRows(CodableRealWorldRow(
    name: "LLM message", payload: Payloads.llmMessage, type: BenchmarkLLMMessage.self
  ))
  addCodableRows(CodableRealWorldRow(
    name: "Qwen 3 search tool call",
    payload: Payloads.qwen3SearchToolCall,
    type: BenchmarkQwen3ToolCall.self
  ))
  addCodableRows(CodableRealWorldRow(
    name: "Qwen 3 workspace edit tool call",
    payload: Payloads.qwen3WorkspaceEditToolCall,
    type: BenchmarkQwen3ToolCall.self
  ))
  addCodableRows(CodableRealWorldRow(
    name: "Qwen 3 structured response",
    payload: Payloads.qwen3StructuredResponse,
    type: BenchmarkQwen3StructuredResponse.self
  ))
  addCodableRows(CodableRealWorldRow(
    name: "Mesh", payload: Payloads.mesh, type: BenchmarkMesh.self
  ))
}
