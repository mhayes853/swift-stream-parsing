import Foundation

@testable import StreamParsingCore

/// The property the test suites check most often, run on the shipped parser where it can be seen:
/// a document cut at any byte produces the same tokens as the document whole.
///
/// `expectChunkBoundaryEquivalence` makes the same sweep in the tests, comparing the finished
/// values. This records what the comparison hides -- *which* parse call delivered each token when
/// the cut falls where it does. A key or a number the cut runs through arrives whole in the second
/// call, because the parser buffers it; a string's content arrives in both, because it streams; a
/// literal waits for its last byte. The trace fails the build if any split's tokens, joined back
/// up, differ from the whole parse's.
enum TestTraces {
  static func chunkCuts(sample: String) throws -> ChunkCutTrace {
    let bytes = Array(sample.utf8)
    let whole = Self.normalize(try Self.parse(bytes, split: nil))
    var splits: [ChunkCutTrace.Split] = []
    var verified = true
    for at in 1..<bytes.count {
      let tokens = Self.normalize(try Self.parse(bytes, split: at))
      if tokens.map(\.value) != whole.map(\.value) { verified = false }
      splits.append(ChunkCutTrace.Split(at: at, delivery: tokens.map(\.delivery)))
    }
    return ChunkCutTrace(
      sample: sample, bytes: bytes,
      tokens: whole.map { ChunkCutTrace.Token(kind: $0.value.kind, text: $0.value.text) },
      splits: splits, verified: verified)
  }

  /// Events tagged with the call that delivered them: 0 and 1 are the two `parse` calls, 2 is
  /// `finish`. An unsplit parse delivers everything from call 0.
  private static func parse(_ bytes: [UInt8], split: Int?) throws -> [(call: Int, event: RecordingSink.Event)] {
    var parser = JSONParser()
    var sink = RecordingSink()
    var tagged: [(call: Int, event: RecordingSink.Event)] = []
    func drain(_ call: Int) {
      tagged += sink.events.map { (call, $0) }
      sink.events.removeAll()
    }
    let pieces = split.map { [Array(bytes[..<$0]), Array(bytes[$0...])] } ?? [bytes]
    for (call, piece) in pieces.enumerated() {
      try piece.withUnsafeBufferPointer { buffer in
        sink.base = UnsafeRawPointer(buffer.baseAddress!)
        sink.count = buffer.count
        try parser.parse(buffer, into: &sink)
      }
      drain(call)
    }
    try parser.finish(into: &sink)
    drain(2)
    return tagged
  }

  private struct Normalized {
    var value: Value
    var delivery: String
  }

  private struct Value: Equatable {
    var kind: String
    var text: String
  }

  /// Folds a string's `stringBegin`/`stringChunk`/`stringEnd` into one token, since how content is
  /// cut into chunks is a property of the chunking and not of the document. A token is `head`,
  /// `tail` or `finish` when one call delivered all of it, and `both` when its content arrived in
  /// the two parse calls.
  private static func normalize(_ events: [(call: Int, event: RecordingSink.Event)]) -> [Normalized] {
    var out: [Normalized] = []
    var open: (text: String, calls: Set<Int>)?
    func name(_ calls: Set<Int>) -> String {
      if calls.count > 1 { return "both" }
      switch calls.first ?? 0 {
      case 0: return "head"
      case 1: return "tail"
      default: return "finish"
      }
    }
    for (call, event) in events {
      switch event.kind {
      case "stringBegin": open = ("", [call])
      case "stringChunk":
        open?.text += event.text ?? ""
        open?.calls.insert(call)
      case "stringEnd":
        if var string = open {
          string.calls.insert(call)
          out.append(Normalized(value: Value(kind: "string", text: string.text), delivery: name(string.calls)))
        }
        open = nil
      default:
        let text: String
        switch event.kind {
        case "beginObject": text = "{"
        case "endObject": text = "}"
        case "beginArray": text = "["
        case "endArray": text = "]"
        default: text = event.text ?? ""
        }
        out.append(Normalized(value: Value(kind: event.kind, text: text), delivery: name([call])))
      }
    }
    return out
  }
}

/// A document cut at every byte, and which call delivered each of its tokens at each cut.
struct ChunkCutTrace: Encodable {
  var sample: String
  var bytes: [UInt8]
  /// The whole document's tokens, strings folded to one token each.
  var tokens: [Token]
  var splits: [Split]
  /// Every split's tokens, joined, equal the whole parse's.
  var verified: Bool

  struct Token: Encodable {
    var kind: String
    var text: String
  }

  struct Split: Encodable {
    /// The first byte of the second chunk.
    var at: Int
    /// Per token: `head`, `tail`, `both` or `finish`.
    var delivery: [String]
  }
}
