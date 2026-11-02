import CustomDump
import Foundation
import StreamParsing
import StreamParsingCore
import Testing

// MARK: - 1. Real-world fidelity
//
// The library's first promise: whatever it hands back for a real document is what `JSONDecoder`
// would have produced for the same declaration. Every row here runs on a real corpus.

@Suite
struct `Real-world fidelity` {
  // RW-1
  @Test(arguments: Corpus.allCases)
  func `A typed parse of every corpus equals JSONDecoder's`(corpus: Corpus) throws {
    try expectCorpusMatchesFoundation(corpus, chunking: .whole)
  }

  // RW-2
  @Test(arguments: Corpus.allCases)
  func `The raw event stream of every corpus rebuilds JSONDecoder's tree`(corpus: Corpus) throws {
    var sink = TreeSink()
    try parseRaw(try corpus.bytes, into: &sink)
    let expected = try foundationTree(corpus)
    if sink.root != expected {
      Issue.record("\(corpus):\n\(diff(sink.root, expected) ?? "")")
    }
  }

  // RW-3
  @Test
  func `Minified, pretty-printed, and unicode-escaped Twitter decode to one value`() throws {
    let minified = try streamValue(try Corpus.twitter.bytes, as: CorpusTwitterFull.self)
    let spaced = try streamValue(try Corpus.twitterSpaced.bytes, as: CorpusTwitterFull.self)
    let escaped = try streamValue(try Corpus.twitterEscaped.bytes, as: CorpusTwitterFull.self)
    #expect(minified.statuses.count == 100)
    #expect(spaced == minified)
    #expect(escaped == minified)
  }

  // RW-4
  // `==` on `Double` cannot tell 0.0 from -0.0; a bit pattern can. canada holds 111 126
  // coordinates, nearly all with 15-17 significant digits -- the hard cases for decimal-to-binary.
  @Test
  func `Every canada coordinate is bit-identical to Foundation's`() throws {
    let expected = try foundationValue(.canada, as: CorpusCanada.self)
    let actual = try streamValue(try Corpus.canada.bytes, as: CorpusCanada.self)
    let expectedBits = expected.features.flatMap(\.geometry.coordinates).joined()
      .flatMap { [$0.x.bitPattern, $0.y.bitPattern] }
    let actualBits = actual.features.flatMap(\.geometry.coordinates).joined()
      .flatMap { [$0.x.bitPattern, $0.y.bitPattern] }
    #expect(expectedBits.count == 111_126)
    #expect(actualBits == expectedBits)
  }

  // RW-5
  // 378 of the integer literals in twitter.json have no exact `Double`, so any trip through
  // floating point -- a parser that accumulates every number as a double -- changes them.
  // (The corpus's `id_str` fields cannot serve as the oracle: upstream already rounded the numeric
  // `id`s, so the two disagree in the file itself.)
  @Test
  func `Integers past 2^53 survive exactly`() throws {
    let expected = try foundationValue(.twitter, as: CorpusTwitterFull.self)
    let actual = try streamValue(try Corpus.twitter.bytes, as: CorpusTwitterFull.self)
    let expectedIDs = expected.statuses.flatMap { [$0.id, $0.user.id] }
    let actualIDs = actual.statuses.flatMap { [$0.id, $0.user.id] }
    #expect(expectedIDs.contains { Int(exactly: Double($0)) != $0 }, "the check has no teeth")
    #expect(actualIDs == expectedIDs)
  }

  // RW-6
  // A model that names three fields of a 631 KB document: everything else -- nested objects,
  // arrays of objects, retweets -- must be skipped without disturbing what is read.
  @Test(arguments: [Corpus.twitter, .twitterEscaped, .twitterSpaced])
  func `A model that reads a few fields skips the rest of a real document`(corpus: Corpus) throws {
    let expected = try foundationValue(corpus, as: CorpusTwitterMatched.self)
    let actual = try streamValue(try corpus.bytes, as: CorpusTwitterMatched.self)
    expectNoDifference(actual, expected)
  }

  // RW-7
  @Test
  func `The snake case key strategy reads keys the way JSONDecoder's does`() throws {
    let expected = try foundationValue(
      .githubEvents, as: [CorpusGitHubEventCamel].self, keyDecodingStrategy: .convertFromSnakeCase
    )
    let actual = try streamValue(try Corpus.githubEvents.bytes, as: [CorpusGitHubEventCamel].self)
    #expect(actual.count == 30)
    #expect(actual.allSatisfy { !$0.createdAt.isEmpty && !$0.actor.avatarUrl.isEmpty })
    expectNoDifference(actual, expected)
  }
}
