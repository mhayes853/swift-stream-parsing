import CustomDump
import Foundation
import StreamParsing
import Testing

// MARK: - Chunk boundary equivalence

// Resumability is where streaming parsers break: a token straddling a chunk boundary exercises
// carry-over state that a single call parse never touches.
func expectChunkBoundaryEquivalence<Value: StreamParseableValue>(
  _ json: String,
  as type: Value.Type,
  configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration(),
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  let bytes = Array(json.utf8)

  let expected = try parseWhole(bytes, as: Value.self, configuration: configuration)

  for split in 1..<max(bytes.count, 2) {
    let head = Array(bytes[..<split])
    let tail = Array(bytes[split...])
    let actual = try parseChunks([head, tail], as: Value.self, configuration: configuration)
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

  let byteByByte = try parseChunks(bytes.map { [$0] }, as: Value.self, configuration: configuration)
  if let difference = diff(expected, byteByByte) {
    Issue.record(
      "Byte by byte produced a different value.\n\(difference)",
      sourceLocation: sourceLocation
    )
  }
}

// A parser that only rejects malformed input when it happens to see it in one piece is worse
// than one that never rejects it, so failures get the same treatment as successes.
func expectChunkBoundaryFailureEquivalence<Value: StreamParseableValue>(
  _ json: String,
  as type: Value.Type,
  configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration(),
  sourceLocation: SourceLocation = #_sourceLocation
) {
  let bytes = Array(json.utf8)

  guard
    let expected = failureReason(
      forParsing: [bytes], as: Value.self, configuration: configuration
    )
  else {
    Issue.record("Expected the bulk parse to fail.", sourceLocation: sourceLocation)
    return
  }

  for split in 1..<max(bytes.count, 2) {
    let chunks = [Array(bytes[..<split]), Array(bytes[split...])]
    let actual = failureReason(forParsing: chunks, as: Value.self, configuration: configuration)
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

private func parseWhole<Value: StreamParseableValue>(
  _ bytes: [UInt8],
  as type: Value.Type,
  configuration: JSONStreamParserConfiguration
) throws -> Value {
  try parseChunks([bytes], as: Value.self, configuration: configuration)
}

private func parseChunks<Value: StreamParseableValue>(
  _ chunks: [[UInt8]],
  as type: Value.Type,
  configuration: JSONStreamParserConfiguration
) throws -> Value {
  var parser = JSONStreamParser<Value>(configuration: configuration)
  parser.registerHandlers()
  var value = Value.initialParseableValue()
  for chunk in chunks {
    try parser.parse(bytes: chunk, into: &value)
  }
  try parser.finish(reducer: &value)
  return value
}

private func failureReason<Value: StreamParseableValue>(
  forParsing chunks: [[UInt8]],
  as type: Value.Type,
  configuration: JSONStreamParserConfiguration
) -> JSONStreamParsingError.Reason? {
  do {
    _ = try parseChunks(chunks, as: Value.self, configuration: configuration)
    return nil
  } catch let error as JSONStreamParsingError {
    return error.reason
  } catch {
    return nil
  }
}
