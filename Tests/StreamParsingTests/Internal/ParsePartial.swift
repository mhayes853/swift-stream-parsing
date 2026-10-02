import StreamParsing
import StreamParsingCore

// Drives the sink based parser end to end, which is what the support type tests want: the
// conversion protocols are only interesting in the shape the parser actually calls them.
func parsePartial<Root: StreamParseableRoot>(
  _ json: String, into value: inout Root, chunk: Int = .max
) throws {
  try withUnsafeMutablePointer(to: &value) { pointer in
    var parser = JSONParser()
    var sink = PartialSink(root: pointer)
    let bytes = Array(json.utf8)
    try bytes.withUnsafeBufferPointer { input in
      var i = 0
      while i < input.count {
        let count = min(chunk, input.count - i)
        try parser.parse(
          UnsafeBufferPointer(start: input.baseAddress! + i, count: count), into: &sink
        )
        i += count
      }
    }
    try parser.finish(into: &sink)
  }
}

// The rejection half of `parsePartial`, which every sink suite otherwise spells out: a sink that
// refuses a token surfaces as `.sinkRejectedToken`, and what those tests assert is the reason
// inside it. `nil` means accepted, and so does a grammar error -- a suite asking this question
// has already established the document is well formed.
func streamFailureReason<Root: StreamParseableRoot>(
  _ json: String, into value: inout Root, chunk: Int = .max
) -> StreamSinkFailure.Reason? {
  do {
    try parsePartial(json, into: &value, chunk: chunk)
    return nil
  } catch let error as JSONParsingError {
    guard case .sinkRejectedToken(let failure) = error.reason else { return nil }
    return failure.reason
  } catch {
    return nil
  }
}

// The same, for the common case where the destination is just the root's initial value.
func streamFailureReason<Root: StreamParseableRoot>(
  _ json: String, as type: Root.Type, chunk: Int = .max
) -> StreamSinkFailure.Reason? {
  var value = Root.streamInitialValue()
  return streamFailureReason(json, into: &value, chunk: chunk)
}
