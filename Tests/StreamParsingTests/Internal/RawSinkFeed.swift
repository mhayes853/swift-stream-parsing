import StreamParsingCore

// Drives the raw sink parser over a document in fixed size chunks, which is the loop every raw
// sink test writes: a chunk boundary is the only way to reach the parser's carry-over buffer, so
// the same document is usually run at several chunk sizes and at `.max`.
//
// The parser is created here rather than passed in: every caller wants a fresh one per run, and
// one that is not fresh would carry state across documents.
func feed<Sink: StreamParseSink & ~Copyable>(
  _ bytes: [UInt8],
  chunk: Int,
  into sink: inout Sink
) throws(JSONParsingError) {
  var parser = JSONParser()
  try bytes.withUnsafeBufferPointer { input throws(JSONParsingError) in
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

// A `Span` a sink is handed is only valid for the duration of the call, so a recording sink has to
// copy. `withUnsafeBufferPointer` plus `Array.init` is one `memcpy`; appending index by index was
// a retain-free but per-byte loop with a uniqueness check on every element.
func streamCopy(_ span: Span<UInt8>) -> [UInt8] {
  span.withUnsafeBufferPointer { [UInt8]($0) }
}
