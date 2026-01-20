/// Signals terminal stream parsing errors such as calling `finish()` twice.
public struct StreamParsingError: Error, Hashable {
  private enum Kind: Hashable {
    case parserFinished
    case parserThrows
  }

  /// Thrown when `finish()` is invoked more than once on a stream.
  public static let parserFinished = StreamParsingError(.parserFinished)

  /// Thrown when the parser has previously failed and the stream still receives bytes.
  public static let parserThrows = StreamParsingError(.parserThrows)

  private let kind: Kind

  private init(_ kind: Kind) {
    self.kind = kind
  }
}
