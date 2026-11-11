import Foundation
import StreamParsing
import StreamParsingCore
import Testing

// How a document is cut into the chunks a stream receives. Real transports do not hand over
// documents whole: an LLM emits a few bytes per token, a socket hands over whatever the kernel had,
// a file reader hands over pages. The parser's answer must not depend on which.
enum Chunking: Hashable, Sendable, CustomTestStringConvertible {
  /// The whole document in one call.
  case whole
  /// Every chunk `size` bytes, the last one shorter.
  case fixed(Int)
  /// Chunk lengths drawn log-uniformly from `1...maximum` by a seeded generator, so one parse
  /// mixes single bytes, SIMD-block-sized runs, and long spans the way a real stream does.
  case variable(seed: UInt64, maximum: Int)

  var testDescription: String {
    switch self {
    case .whole: "whole"
    case .fixed(let size): "fixed(\(size))"
    case .variable(let seed, let maximum): "variable(seed: \(seed), max: \(maximum))"
    }
  }

  /// The chunk boundaries for a document of `count` bytes, as half-open ranges covering it.
  func ranges(count: Int) -> [Range<Int>] {
    guard count > 0 else { return [] }
    switch self {
    case .whole:
      return [0..<count]
    case .fixed(let size):
      precondition(size > 0)
      return stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
    case .variable(let seed, let maximum):
      precondition(maximum > 0)
      var generator = SplitMix64(seed: seed)
      var ranges = [Range<Int>]()
      var start = 0
      let logMaximum = log(Double(maximum))
      while start < count {
        // Log-uniform: a chunk is as likely to be 1-8 bytes as 512-4096, so the median chunk is
        // about sqrt(maximum) and every scale in between gets exercised in a single parse.
        let unit = Double(generator.next() >> 11) / Double(1 << 53)
        let length = max(1, min(maximum, Int(exp(unit * logMaximum).rounded())))
        let end = min(start + length, count)
        ranges.append(start..<end)
        start = end
      }
      return ranges
    }
  }
}

/// The chunkings every whole-corpus acceptance row runs: single bytes, sizes either side of the
/// 16- and 64-byte SIMD blocks, a typical page, a chunk bigger than any corpus, and three seeded
/// variable schedules.
let acceptanceChunkings: [Chunking] = [
  .fixed(1), .fixed(2), .fixed(3), .fixed(7), .fixed(15), .fixed(16), .fixed(17),
  .fixed(63), .fixed(64), .fixed(65), .fixed(127), .fixed(4096), .fixed(65_536),
  .fixed(16 * 1024 * 1024), .whole,
  .variable(seed: 1, maximum: 64), .variable(seed: 2, maximum: 4096),
  .variable(seed: 3, maximum: 1 << 20),
]

/// Feeds `bytes` to a fresh `Model` stream in the given chunking and returns the finished partial.
func parse<Model: StreamParseable>(
  _ bytes: [UInt8],
  as type: Model.Type,
  chunking: Chunking = .whole,
  format: JSONStreamFormat = .json()
) throws -> Model.Partial {
  var stream = PartialsStream<Model>(from: format)
  for range in chunking.ranges(count: bytes.count) {
    try stream.next(bytes[range])
  }
  return try stream.finishPartial()
}

/// The `JSONParsingError` a parse throws, or `nil` if it succeeds or throws something else.
func parsingError<Value: StreamParseable>(
  _ bytes: [UInt8],
  as type: Value.Type,
  chunking: Chunking = .whole
) -> JSONParsingError? {
  do {
    _ = try parse(bytes, as: type, chunking: chunking)
    return nil
  } catch let error as JSONParsingError {
    return error
  } catch {
    return nil
  }
}

/// A small, fast, seedable generator, so a failing variable schedule reproduces exactly.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) { self.state = seed }

  mutating func next() -> UInt64 {
    self.state &+= 0x9E37_79B9_7F4A_7C15
    var z = self.state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
