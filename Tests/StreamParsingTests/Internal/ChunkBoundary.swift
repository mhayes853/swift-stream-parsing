import CustomDump
import Foundation
import StreamParsing
import Testing

// MARK: - Chunk boundary equivalence

// Resumability is where streaming parsers break: a token straddling a chunk boundary exercises
// carry-over state that a single call parse never touches.
func expectChunkBoundaryEquivalence<Value: StreamParseableRoot>(
  _ json: String,
  as type: Value.Type,
  format: JSONStreamFormat = .json(),
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let bytes = Array(json.utf8)

  let expected = try parseWhole(bytes, as: Value.self, format: format)

  for split in 1..<max(bytes.count, 2) {
    let head = Array(bytes[..<split])
    let tail = Array(bytes[split...])
    let actual = try parseChunks([head, tail], as: Value.self, format: format)
    if let difference = diff(expected, actual) {
      Issue.record(
        """
        Split at \(split) produced a different value.
        head: \(String(decoding: head, as: UTF8.self))
        tail: \(String(decoding: tail, as: UTF8.self))
        \(difference)
        """,
        sourceLocation: sourceLocation
      )
      return
    }
  }

  let byteByByte = try parseChunks(bytes.map { [$0] }, as: Value.self, format: format)
  if let difference = diff(expected, byteByByte) {
    Issue.record(
      "Byte by byte produced a different value.\n\(difference)",
      sourceLocation: sourceLocation
    )
  }
}

// A parser that only rejects malformed input when it happens to see it in one piece is worse
// than one that never rejects it, so failures get the same treatment as successes. The whole
// error is compared — reason and byte offset — since a position that moves with the chunking
// is a diagnostic that cannot be trusted.
func expectChunkBoundaryFailureEquivalence<Value: StreamParseableRoot>(
  _ json: String,
  as type: Value.Type,
  format: JSONStreamFormat = .json(),
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let bytes = Array(json.utf8)

  guard let expected = parsingFailure(forParsing: [bytes], as: Value.self, format: format) else {
    Issue.record("Expected the bulk parse to fail.", sourceLocation: sourceLocation)
    return
  }

  for split in 1..<max(bytes.count, 2) {
    let chunks = [Array(bytes[..<split]), Array(bytes[split...])]
    let actual = parsingFailure(forParsing: chunks, as: Value.self, format: format)
    guard actual == expected else {
      Issue.record(
        "Split at \(split) reported \(String(describing: actual)) rather than \(expected).",
        sourceLocation: sourceLocation
      )
      return
    }
  }
}

// MARK: - Helpers

private func parseWhole<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  as type: Value.Type,
  format: JSONStreamFormat
) throws -> Value {
  try parseChunks([bytes], as: Value.self, format: format)
}

private func parseChunks<Value: StreamParseableRoot>(
  _ chunks: [[UInt8]],
  as type: Value.Type,
  format: JSONStreamFormat
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: format)
  for chunk in chunks {
    try stream.next(chunk)
  }
  return try stream.finish()
}

private func parsingFailure<Value: StreamParseableRoot>(
  forParsing chunks: [[UInt8]],
  as type: Value.Type,
  format: JSONStreamFormat
) -> JSONParsingError? {
  do {
    _ = try parseChunks(chunks, as: Value.self, format: format)
    return nil
  } catch let error as JSONParsingError {
    return error
  } catch {
    return nil
  }
}
