/// Signals terminal stream parsing errors such as calling `finish()` twice.
public struct StreamParsingError: Error, Hashable {
  private enum Kind: Hashable {
    case parserFinished
  }

  /// Thrown when `finish()` is invoked more than once on a stream.
  public static let parserFinished = StreamParsingError(.parserFinished)

  private let kind: Kind

  private init(_ kind: Kind) {
    self.kind = kind
  }
}
