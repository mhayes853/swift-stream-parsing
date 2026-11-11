import Foundation

// The real world corpora live in the benchmark package, which the library tests do not depend on,
// so they are read by path from the package root rather than as test resources.
//
// Every corpus is loaded through a `static let` below, so a document several suites want --
// `canada.json` is read by the two differential suites and by the block walk suite -- is read from
// disk once per process rather than once per row. `canada.json` alone is 2.2 MB.
//
// A missing file comes back as `nil`; the call sites all turn that into a failure with
// `try #require`, so a checkout without the benchmark resources fails loudly and identically
// everywhere rather than silently passing a row that converted nothing.
func streamBenchmarkCorpus(_ name: String) -> [UInt8]? {
  let file = name.hasSuffix(".json") ? name : "\(name).json"
  switch file {
  case "canada.json": return StreamBenchmarkCorpora.canada
  case "citm_catalog.json": return StreamBenchmarkCorpora.citmCatalog
  case "github_events.json": return StreamBenchmarkCorpora.githubEvents
  case "gsoc-2018.json": return StreamBenchmarkCorpora.gsoc2018
  case "llm_message.json": return StreamBenchmarkCorpora.llmMessage
  case "mesh.json": return StreamBenchmarkCorpora.mesh
  case "twitter.json": return StreamBenchmarkCorpora.twitter
  case "twitterescaped.json": return StreamBenchmarkCorpora.twitterEscaped
  default: return streamReadBenchmarkCorpus(file)
  }
}

// `static let` is lazy and initialised exactly once under `swift_once`, which is what makes this
// safe to read from the parallel test runner without a lock of its own.
private enum StreamBenchmarkCorpora {
  static let canada = streamReadBenchmarkCorpus("canada.json")
  static let citmCatalog = streamReadBenchmarkCorpus("citm_catalog.json")
  static let githubEvents = streamReadBenchmarkCorpus("github_events.json")
  static let gsoc2018 = streamReadBenchmarkCorpus("gsoc-2018.json")
  static let llmMessage = streamReadBenchmarkCorpus("llm_message.json")
  static let mesh = streamReadBenchmarkCorpus("mesh.json")
  static let twitter = streamReadBenchmarkCorpus("twitter.json")
  static let twitterEscaped = streamReadBenchmarkCorpus("twitterescaped.json")
}

private func streamReadBenchmarkCorpus(_ file: String) -> [UInt8]? {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Internal
    .deletingLastPathComponent()  // StreamParsingTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // package root
  let url = root.appendingPathComponent("Benchmarks/StreamParsingBenchmarks/Resources/\(file)")
  guard let data = try? Data(contentsOf: url) else { return nil }
  return [UInt8](data)
}
