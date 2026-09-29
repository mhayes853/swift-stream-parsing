import Testing

import StreamParsing
import StreamParsingCore

// `partials(of:from:)` has one overload constrained to `StreamParseable` and one to
// `StreamParseableRoot`, and nothing orders them for a type that conforms to both --
// `StreamEmptyObject` does, and so does any macro `Partial` that is itself `StreamParseable`.
// This is here to fail at compile time if the ordering is ever lost.
@Suite
struct `Partials overload probe` {
  @Test
  func `A type conforming to both protocols resolves one partials overload`() throws {
    let partials = try Array("{}".utf8).partials(of: StreamEmptyObject.self, from: .json())
    #expect(partials.count >= 1)
  }
}
