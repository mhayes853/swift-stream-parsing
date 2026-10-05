import StreamParsing

/// A parseable whose partial is a Swift `String`.
///
/// `String.Partial` is a `StreamString`, so `PartialsStream<String>` writes into that. A stream
/// over this type writes into `String` storage instead, which is how a member of a type declared
/// `@StreamParseable(partialStrings: .string)` is stored. The tests that exercise `String` as a
/// destination of the parser use it as the root.
struct SwiftStringStorage: StreamParseable {
  typealias Partial = String

  var value: String

  var streamPartialValue: String { self.value }

  init(value: String) {
    self.value = value
  }

  init?(streamPartial: String) {
    self.value = streamPartial
  }

  static func streamValueOrInitial(from partial: String) -> Self {
    Self(value: partial)
  }
}
