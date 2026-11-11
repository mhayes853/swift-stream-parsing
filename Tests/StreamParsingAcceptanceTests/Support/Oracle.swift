import CustomDump
import Foundation
import StreamParsing
import StreamParsingCore
import Testing

// The oracle for a corpus is computed once per process and shared across every row that checks
// against it: `JSONDecoder` on canada takes about as long as the parse under test, and the chunking
// matrix asks for it eighteen times.
final class OracleCache: @unchecked Sendable {
  static let shared = OracleCache()

  private let lock = NSLock()
  private var values = [String: Any]()

  func value<T>(_ key: String, _ make: () throws -> T) rethrows -> T {
    self.lock.lock()
    if let cached = self.values[key] as? T {
      self.lock.unlock()
      return cached
    }
    self.lock.unlock()
    let made = try make()
    self.lock.lock()
    self.values[key] = made
    self.lock.unlock()
    return made
  }
}

/// `JSONDecoder`'s reading of a corpus as `Model`, cached.
func foundationValue<Model: Decodable>(
  _ corpus: Corpus,
  as type: Model.Type,
  keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy = .useDefaultKeys
) throws -> Model {
  try OracleCache.shared.value("\(corpus.rawValue) as \(Model.self)") {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = keyDecodingStrategy
    return try decoder.decode(Model.self, from: try corpus.data)
  }
}

/// `JSONDecoder`'s plain tree of a corpus, cached.
func foundationTree(_ corpus: Corpus) throws -> JSONValue {
  try OracleCache.shared.value("\(corpus.rawValue) as tree") {
    try JSONValue.foundation(try corpus.bytes)
  }
}

/// The stream parser's reading of `bytes` as `Model`: parse into `Model.Partial`, then convert,
/// filling members the document never mentions from their initial values -- the same
/// default-on-missing rule the Codable models spell out.
func streamValue<Model: StreamParseable>(
  _ bytes: [UInt8],
  as type: Model.Type,
  chunking: Chunking = .whole,
  format: JSONStreamFormat = .json()
) throws -> Model {
  let partial = try parse(bytes, as: Model.self, chunking: chunking, format: format)
  return Model(orInitial: partial)
}

/// The model each corpus is checked through, and the check itself: the stream parser's value under
/// `chunking` must equal `JSONDecoder`'s.
func expectCorpusMatchesFoundation(
  _ corpus: Corpus,
  chunking: Chunking,
  format: JSONStreamFormat = .json(),
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  func check<Model: StreamParseable & Decodable & Equatable>(_ type: Model.Type) throws {
    let expected = try foundationValue(corpus, as: Model.self)
    let actual = try streamValue(try corpus.bytes, as: Model.self, chunking: chunking, format: format)
    // Equality first: diffing two multi-megabyte values is only worth paying for on failure.
    if actual != expected {
      Issue.record(
        "\(corpus) at \(chunking) differs from JSONDecoder:\n\(diff(actual, expected) ?? "")",
        sourceLocation: sourceLocation
      )
    }
  }
  switch corpus {
  case .canada: try check(CorpusCanada.self)
  case .citmCatalog: try check(CorpusCITM.self)
  case .githubEvents: try check([CorpusGitHubEvent].self)
  case .gsoc2018: try check([String: CorpusGSoCProject].self)
  case .llmMessage: try check(CorpusLLMMessage.self)
  case .mesh: try check(CorpusMesh.self)
  case .twitter, .twitterEscaped, .twitterSpaced: try check(CorpusTwitterFull.self)
  }
}

/// Runs `body` on a thread with a 64 MB stack. The compiler-derived `==` on a large macro
/// `Partial` (the Twitter tree is about 12 KB of nested optionals) copies its members into its
/// frame in debug builds, which overflows the 512 KB stacks of Swift Concurrency's pool threads
/// that the test runner uses. The overflow is the test's, not the library's.
func onLargeStack<T>(_ body: @escaping () throws -> T) throws -> T {
  let box = LargeStackResult<T>(body: body)
  let done = DispatchSemaphore(value: 0)
  let thread = Thread {
    box.result = Result { try box.body() }
    done.signal()
  }
  thread.stackSize = 64 << 20
  thread.start()
  done.wait()
  return try box.result!.get()
}

/// Carries `body` and its result across the thread hop. `Thread`'s block is `@Sendable`, and
/// `body` is not; the caller blocks on the semaphore until the thread is done, so nothing runs
/// concurrently with it.
private final class LargeStackResult<T>: @unchecked Sendable {
  let body: () throws -> T
  var result: Result<T, any Error>?

  init(body: @escaping () throws -> T) {
    self.body = body
  }
}
