import Testing

@testable import StreamParsingCore

// `JSONParser` is exactly 64 bytes with no padding left (see the note above its fields). A new
// stored property compiles fine and silently grows it -- past a 64-byte line, and shifting the sink
// that follows it in `PartialsStream` -- so the size is pinned here: a field that has to be added
// is a layout decision to measure, not a side effect.
@Suite("JSONParser layout tests")
struct JSONParserLayoutTests {
  @Test("Parser Is Sixty Four Bytes")
  func parserIsSixtyFourBytes() {
    #expect(MemoryLayout<JSONParser>.size == 64)
    #expect(MemoryLayout<JSONParser>.stride == 64)
  }
}
