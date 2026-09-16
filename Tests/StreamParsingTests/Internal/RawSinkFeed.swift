import StreamParsingCore

// Drives the raw sink parser over a document in fixed size chunks, which is the loop every raw
// sink test writes: a chunk boundary is the only way to reach the parser's carry-over buffer, so
// the same document is usually run at several chunk sizes and at `.max`.
//
// The parser is created here rather than passed in: every caller wants a fresh one per run, and
// one that is not fresh would carry state across documents.
// There are exactly three shapes a raw sink test feeds in: fixed size chunks, a single split at a
// chosen byte, and one byte at a time. `bufferCapacity` and `windowThreshold` are the only knobs
// any of them varies, so they ride along as defaults rather than as a fourth shape.
func feed<Sink: StreamParseSink & ~Copyable>(
  _ bytes: [UInt8],
  chunk: Int = .max,
  into sink: inout Sink,
  bufferCapacity: Int = 4096,
  windowThreshold: Int = .max
) throws(JSONParsingError) {
  var parser = JSONParser(bufferCapacity: bufferCapacity, windowThreshold: windowThreshold)
  try streamDrive(bytes, chunk: chunk, through: &parser, into: &sink)
}

// The caller-supplied buffer form, which is the one setting that cannot be spelled as a default.
func feed<Sink: StreamParseSink & ~Copyable>(
  _ bytes: [UInt8],
  chunk: Int = .max,
  into sink: inout Sink,
  buffer: UnsafeMutableBufferPointer<UInt8>,
  windowThreshold: Int = .max
) throws(JSONParsingError) {
  var parser = JSONParser(buffer: buffer, windowThreshold: windowThreshold)
  try streamDrive(bytes, chunk: chunk, through: &parser, into: &sink)
}

// A single boundary at a chosen byte. A split is what a fixed chunk size can never place exactly,
// and "at every split" is the sweep most of these suites actually want.
func feed<Sink: StreamParseSink & ~Copyable>(
  _ bytes: [UInt8],
  splitAt: Int,
  into sink: inout Sink,
  bufferCapacity: Int = 4096,
  windowThreshold: Int = .max
) throws(JSONParsingError) {
  var parser = JSONParser(bufferCapacity: bufferCapacity, windowThreshold: windowThreshold)
  try bytes.withUnsafeBufferPointer { input throws(JSONParsingError) in
    let first = UnsafeBufferPointer(start: input.baseAddress, count: splitAt)
    let second = UnsafeBufferPointer(
      start: input.baseAddress! + splitAt, count: input.count &- splitAt
    )
    if !first.isEmpty { try parser.parse(first, into: &sink) }
    if !second.isEmpty { try parser.parse(second, into: &sink) }
  }
  try parser.finish(into: &sink)
}

// The byte at a time form, which takes the parser's single-byte entry point rather than a one
// byte buffer: it is a different code path, not just the smallest chunk size.
func feedByByte<Sink: StreamParseSink & ~Copyable>(
  _ bytes: [UInt8],
  into sink: inout Sink,
  bufferCapacity: Int = 4096,
  windowThreshold: Int = .max
) throws(JSONParsingError) {
  var parser = JSONParser(bufferCapacity: bufferCapacity, windowThreshold: windowThreshold)
  for byte in bytes {
    try parser.parse(byte: byte, into: &sink)
  }
  try parser.finish(into: &sink)
}

// The parser is created by the callers above rather than here: every caller wants a fresh one per
// run, and one that is not fresh would carry state across documents.
private func streamDrive<Sink: StreamParseSink & ~Copyable>(
  _ bytes: [UInt8],
  chunk: Int,
  through parser: inout JSONParser,
  into sink: inout Sink
) throws(JSONParsingError) {
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
