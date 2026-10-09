import Testing

import StreamParsing
import StreamParsingCore

// A partial is itself parseable, with `Partial == Self`, so the one `partials(of:from:)` takes a
// model type and its partial alike. `StreamEmptyObject` is a partial with no model, and any macro
// `Partial` is another. This is here to fail at compile time if either spelling stops resolving.
@Suite
struct `Partials overload probe` {
  @Test
  func `A partial type is accepted where a parseable type is`() throws {
    let partials = try Array("{}".utf8).partials(of: StreamEmptyObject.self, from: .json())
    #expect(partials.count >= 1)
  }
}
