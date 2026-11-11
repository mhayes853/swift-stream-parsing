import CustomDump
import Foundation
import StreamParsing
import StreamParsingCore
import Testing

// MARK: - 7. Lifecycle, resources, and the raw layer
//
// What holds up a long-running consumer: streams that are reused, misused, run concurrently, or
// given the smallest buffer, and the raw sink interface for callers who skip the typed layer.

@Suite
struct `Lifecycle and resources` {
  // LC-1
  // `finish()` is the strict end of a stream: it hands back the whole model, or says the document
  // did not describe one. A stream that has failed refuses everything after.
  @Test
  func `A stream finishes with the whole model or says why it cannot, and refuses input after failing`()
    throws
  {
    var complete = PartialsStream<StreamProfile>(from: .json())
    try complete.next(Array(#"{"id":1,"name":"a","isActive":true}"#.utf8))
    #expect(try complete.finish() == StreamProfile(id: 1, name: "a", isActive: true))

    var incomplete = PartialsStream<StreamProfile>(from: .json())
    try incomplete.next(Array(#"{"id":1}"#.utf8))
    // A noncopyable stream that is consumed cannot be captured by a closure at all, so these are
    // caught by hand rather than with `#expect(throws:)`.
    do {
      _ = try incomplete.finish()
      Issue.record("an incomplete document finished")
    } catch {
      #expect(error as? StreamParsingError == .incompleteValue)
    }

    var failed = PartialsStream<StreamProfile>(from: .json())
    do {
      try failed.next(Array(#"{"id":x"#.utf8))
      Issue.record("a malformed document was accepted")
    } catch {
      #expect(error is JSONParsingError)
    }
    do {
      try failed.next(Array("1".utf8))
      Issue.record("a failed stream accepted more input")
    } catch {
      #expect(error as? StreamParsingError == .parserFailed)
    }
    do {
      _ = try failed.finish()
      Issue.record("a failed stream finished")
    } catch {
      #expect(error as? StreamParsingError == .parserFailed)
    }
  }

  // LC-2
  // `reset` returns a stream to a clean slate, after success and after failure: nothing from the
  // previous document -- parser state, half-built containers, an error -- leaks into the next.
  @Test
  func `A reset stream parses the next document as if it were new`() throws {
    let expected = try foundationValue(.twitter, as: CorpusTwitterFull.self)
    var stream = PartialsStream<CorpusTwitterFull>(from: .json())

    try stream.next(try Corpus.twitterEscaped.bytes)
    _ = try stream.finishAndReset()

    // Abandon a document halfway through a string, then reset.
    let bytes = try Corpus.twitter.bytes
    try stream.next(bytes[..<(bytes.count / 2)])
    stream.reset()

    // Fail a document, then reset.
    do {
      try stream.next(Array(#"{"statuses":[}"#.utf8))
      Issue.record("a malformed document was accepted")
    } catch {
      #expect(error is JSONParsingError)
    }
    stream.reset()

    try stream.next(bytes)
    // Hoisted: `expectNoDifference` takes autoclosures, which cannot consume the stream.
    let final = try stream.finishPartial()
    expectNoDifference(CorpusTwitterFull(orInitial: final), expected)
  }

  // LC-3
  // Strings stream rather than buffer, so only keys, numbers, and literals cut by a chunk boundary
  // need the parser's buffer -- which makes the 64-byte minimum enough for every real corpus.
  @Test(arguments: Corpus.allCases)
  func `Real documents parse with the minimum buffer under hostile chunking`(corpus: Corpus) throws {
    try expectCorpusMatchesFoundation(
      corpus, chunking: .variable(seed: 99, maximum: 96), format: .json(bufferCapacity: 64)
    )
  }

  // LC-4
  // A token longer than the buffer that arrives in pieces cannot be reassembled; the parser must
  // say so rather than misparse it. The same token arriving whole needs no buffer at all.
  @Test
  func `A token longer than the buffer is reported, never misparsed`() throws {
    let key = String(repeating: "k", count: 100)
    let number = "1" + String(repeating: "0", count: 99)
    for json in [#"{"\#(key)":1}"#, "[\(number)]"] {
      let bytes = Array(json.utf8)
      #expect(rawParsingError(bytes, bufferCapacity: 64) == nil, "whole")
      expectNoDifference(
        rawParsingError(bytes, chunking: .fixed(1), bufferCapacity: 64)?.reason, .bufferExhausted
      )
    }
  }

  // LC-5
  // Independent streams share schema caches and nothing else; parsing in parallel must give each
  // the answer it would have had alone.
  @Test
  func `Concurrent streams over real documents each get the right answer`() async throws {
    let twitter = try foundationValue(.twitter, as: CorpusTwitterFull.self)
    let citm = try foundationValue(.citmCatalog, as: CorpusCITM.self)
    let twitterBytes = try Corpus.twitter.bytes
    let citmBytes = try Corpus.citmCatalog.bytes
    try await withThrowingTaskGroup(of: Bool.self) { group in
      for index in 0..<16 {
        let chunking = Chunking.variable(seed: UInt64(index), maximum: 8192)
        if index.isMultiple(of: 2) {
          group.addTask {
            try streamValue(twitterBytes, as: CorpusTwitterFull.self, chunking: chunking) == twitter
          }
        } else {
          group.addTask {
            try streamValue(citmBytes, as: CorpusCITM.self, chunking: chunking) == citm
          }
        }
      }
      for try await matched in group { #expect(matched) }
    }
  }

  // LC-6
  // The raw interface on its own: a sink that keeps only the top level and answers `.skip` for
  // everything below it sees each top-level entry exactly once, and nothing of the skipped
  // interiors -- the SAX-style use the library also supports.
  @Test(arguments: [Corpus.twitter, .citmCatalog, .githubEvents, .gsoc2018, .canada])
  func `A sink that skips subtrees sees exactly the top level of a real document`(
    corpus: Corpus
  ) throws {
    let expected: Int
    switch try foundationTree(corpus) {
    case .object(let members): expected = members.count
    case .array(let elements): expected = elements.count
    default: expected = 1
    }
    for chunking in [Chunking.whole, .fixed(1), .variable(seed: 4, maximum: 1024)] {
      var sink = TopLevelSink()
      try parseRaw(try corpus.bytes, into: &sink, chunking: chunking)
      #expect(sink.topLevelEntries == expected, "\(corpus) at \(chunking)")
      #expect(sink.violations == 0, "\(corpus) at \(chunking)")
    }
  }
}

/// Counts top-level entries and skips every container below the root. Anything delivered from
/// inside a skipped container is a violation -- except its matching end call, which the parser
/// always delivers.
struct TopLevelSink: StreamParseSink {
  var depth = 0
  var topLevelEntries = 0
  var violations = 0
  var streamFailure: StreamSinkFailure?

  private mutating func value() {
    if self.depth == 1 { self.topLevelEntries += 1 } else if self.depth > 1 { self.violations += 1 }
  }

  mutating func beginObject() -> StreamContainerDisposition { self.open() }
  mutating func beginArray() -> StreamContainerDisposition { self.open() }

  private mutating func open() -> StreamContainerDisposition {
    self.value()
    self.depth += 1
    return self.depth == 1 ? .stream : .skip
  }

  mutating func endObject() { self.depth -= 1 }
  mutating func endArray() { self.depth -= 1 }
  mutating func key(_ bytes: Span<UInt8>) { if self.depth != 1 { self.violations += 1 } }
  mutating func stringBegin() { self.value() }
  mutating func stringChunk(_ bytes: Span<UInt8>) { if self.depth != 1 { self.violations += 1 } }
  mutating func stringEnd() {}
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) { self.value() }
  mutating func boolean(_ value: Bool) { self.value() }
  mutating func null() { self.value() }
}
