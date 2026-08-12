import StreamParsing
import StreamParsingCore

// Drives the sink based parser end to end, which is what the support type tests want: the
// conversion protocols are only interesting in the shape the parser actually calls them.
func parsePartial<Root: StreamParseableObject>(
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
