import CustomDump
import Foundation
import StreamParsing
import StreamParsingCore
import Testing

// MARK: - 2. Chunking invariance
//
// A streaming parser that gives a different answer depending on where the transport happened to
// cut the bytes is not a streaming parser. Every row compares results across chunkings; the
// whole-document result is in turn pinned to `JSONDecoder` by the real-world fidelity suite.

@Suite
struct `Chunking invariance` {
  // CH-1
  // From one byte at a time to a single chunk larger than any corpus, through sizes either side of
  // the 16- and 64-byte SIMD blocks, plus seeded schedules that mix every scale within one parse.
  @Test(arguments: Corpus.allCases, acceptanceChunkings)
  func `Every corpus parses identically at every chunk size from one byte to all of it`(
    corpus: Corpus, chunking: Chunking
  ) throws {
    try expectCorpusMatchesFoundation(corpus, chunking: chunking)
  }

  // CH-2
  // The raw layer has its own chunk-boundary state (string chunks, buffered keys and numbers), so
  // it is held to the same standard without the typed layer in between.
  @Test(
    arguments: Corpus.allCases,
    [Chunking.fixed(1), .fixed(63), .variable(seed: 7, maximum: 4096)]
  )
  func `The raw event tree of every corpus does not depend on chunking`(
    corpus: Corpus, chunking: Chunking
  ) throws {
    var sink = TreeSink()
    try parseRaw(try corpus.bytes, into: &sink, chunking: chunking)
    let expected = try foundationTree(corpus)
    if sink.root != expected {
      Issue.record("\(corpus) at \(chunking):\n\(diff(sink.root, expected) ?? "")")
    }
  }

  // CH-3
  // Every possible single cut of one real event: each cut lands somewhere different -- inside a
  // key, a number, an escape, a URL, between a value and its comma -- and all of them must agree.
  @Test
  func `Every two-chunk split of a real GitHub event gives the same value`() throws {
    let event = try firstGitHubEvent()
    let expected = try streamValue(event, as: CorpusGitHubEvent.self)
    #expect(!expected.payload.commits.isEmpty)
    for cut in 1..<event.count {
      var stream = PartialsStream<CorpusGitHubEvent>(from: .json())
      try stream.next(event[..<cut])
      try stream.next(event[cut...])
      let actual = CorpusGitHubEvent(orInitial: try stream.finishPartial())
      guard actual == expected else {
        Issue.record("cut at \(cut) differs:\n\(diff(actual, expected) ?? "")")
        return
      }
    }
  }

  // CH-4
  // A diagnostic whose position moves with the chunking cannot be trusted. A corruption is
  // planted in a real document; every chunking must report the same reason at the same byte.
  @Test(arguments: [
    // An unescaped control byte inside a tweet's text.
    Corruption(corpus: .twitter, needle: #""text": "#, offset: 9, byte: 0x01),
    // A digit replaced by a letter in the middle of a coordinate.
    // Number grammar is not checked inside a skipped subtree (the documented `.skip` contract), so
    // this one is held to chunking invariance on the streaming path only.
    Corruption(
      corpus: .canada, needle: "[-65.6", offset: 4, byte: UInt8(ascii: "x"), checkedWhenSkipped: false
    ),
    // An invalid UTF-8 lead byte in a long description.
    Corruption(corpus: .gsoc2018, needle: #""description": ""#, offset: 40, byte: 0xFF),
    // A closing bracket where a member's value belongs.
    Corruption(corpus: .citmCatalog, needle: #""205705993": "#, offset: -1, byte: UInt8(ascii: "]")),
  ])
  func `A corruption planted in a real document is reported at the same byte under every chunking`(
    corruption: Corruption
  ) throws {
    let (bytes, position) = try corruption.apply()
    let expected = try #require(rawParsingError(bytes), "the corruption was accepted")
    // The error is at or just after the planted byte, never somewhere unrelated.
    #expect((position...position + 1).contains(expected.byteOffset))
    for chunking in [Chunking.fixed(1), .fixed(7), .fixed(64), .variable(seed: 11, maximum: 512)] {
      expectNoDifference(rawParsingError(bytes, chunking: chunking), expected, "\(chunking)")
      if corruption.checkedWhenSkipped {
        expectNoDifference(
          parsingError(bytes, as: JSONValueSkipper.self, chunking: chunking), expected,
          "skipping, \(chunking)"
        )
      }
    }
  }

  // CH-5
  @Test
  func `An async sequence of chunks yields the same value as a synchronous parse`() async throws {
    let bytes = try Corpus.llmMessage.bytes
    let chunks = Chunking.variable(seed: 5, maximum: 2048).ranges(count: bytes.count)
      .map { Array(bytes[$0]) }
    let source = AsyncStream<[UInt8]> { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    }
    var last: CorpusLLMMessage.Partial?
    var updates = 0
    for try await partial in source.partials(of: CorpusLLMMessage.self, from: .json()) {
      last = partial
      updates += 1
    }
    let partial = try #require(last)
    #expect(updates >= chunks.count)
    expectNoDifference(
      CorpusLLMMessage(streamPartial: partial), try foundationValue(.llmMessage, as: CorpusLLMMessage.self)
    )
  }
}

/// A byte overwritten at `offset` past the first occurrence of `needle`.
struct Corruption: Sendable, CustomTestStringConvertible {
  var corpus: Corpus
  var needle: String
  var offset: Int
  var byte: UInt8
  var checkedWhenSkipped = true

  var testDescription: String { "\(corpus) +\(offset) after \(needle)" }

  func apply() throws -> (bytes: [UInt8], position: Int) {
    var bytes = try corpus.bytes
    let needle = Array(self.needle.utf8)
    let start = try #require(
      bytes.indices.first { bytes[$0...].starts(with: needle) }, "needle not found"
    )
    let position = start + needle.count + self.offset
    bytes[position] = self.byte
    return (bytes, position)
  }
}

/// An object root that names no members, so the typed layer skips the whole document: the
/// skipping path must reject a corruption exactly as the streaming path does.
@StreamParseable
struct JSONValueSkipper: Equatable {}

/// The first event of `github_events.json`, sliced from the original bytes so its formatting and
/// escapes are the corpus's own. The file is pretty-printed with two-space top-level indentation.
func firstGitHubEvent() throws -> [UInt8] {
  let bytes = try Corpus.githubEvents.bytes
  let open = Array("\n  {".utf8)
  let close = Array("\n  }".utf8)
  let start = try #require(bytes.indices.first { bytes[$0...].starts(with: open) }) + 3
  let end = try #require(bytes.indices.first { $0 > start && bytes[$0...].starts(with: close) }) + 4
  return Array(bytes[start..<end])
}
