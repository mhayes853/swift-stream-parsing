import Foundation
import Testing

// The real-world corpora live in the benchmark package, which the library's test targets do not
// depend on, so they are read by path from the package root rather than bundled as resources.
// Each is loaded once per process through a `static let` (lazy, `swift_once`-guarded, so safe from
// the parallel runner); `canada.json` alone is 2.2 MB and several suites read it.
//
// A checkout without the benchmark resources fails loudly at `Corpus.bytes` rather than letting a
// row pass having parsed nothing.
enum Corpus: String, CaseIterable, CustomTestStringConvertible, Sendable {
  case canada = "canada.json"
  case citmCatalog = "citm_catalog.json"
  case githubEvents = "github_events.json"
  case gsoc2018 = "gsoc-2018.json"
  case llmMessage = "llm_message.json"
  case mesh = "mesh.json"
  case twitter = "twitter.json"
  case twitterEscaped = "twitterescaped.json"
  case twitterSpaced = "twitterspaced.json"

  var testDescription: String { self.rawValue }

  var bytes: [UInt8] {
    get throws {
      try #require(Loaded.table[self], "\(self.rawValue) is missing from the benchmark resources")
    }
  }

  var data: Data {
    get throws { Data(try self.bytes) }
  }

  private enum Loaded {
    static let table: [Corpus: [UInt8]] = {
      var table = [Corpus: [UInt8]]()
      for corpus in Corpus.allCases {
        if let bytes = read(corpus.rawValue) { table[corpus] = bytes }
      }
      return table
    }()
  }
}

private func read(_ file: String) -> [UInt8]? {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Support
    .deletingLastPathComponent()  // StreamParsingAcceptanceTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // package root
  let url = root.appendingPathComponent("Benchmarks/StreamParsingBenchmarks/Resources/\(file)")
  guard let data = try? Data(contentsOf: url) else { return nil }
  return [UInt8](data)
}
