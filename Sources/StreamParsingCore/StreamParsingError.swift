/// Signals errors raised by stream parsing operations.
public struct StreamParsingError: Error, Hashable {
  private enum Kind: Hashable {
    case multipleSubscribers
    case parserFinished
    case parserThrows
  }

  /// Thrown when more than one iterator attempts to consume an async partials sequence.
  public static let multipleSubscribers = StreamParsingError(.multipleSubscribers)

  /// Thrown when a finished stream receives more bytes or another call to
  /// ``PartialsStream/finish()``.
  public static let parserFinished = StreamParsingError(.parserFinished)

  /// Thrown when the parser has previously failed and the stream still receives bytes.
  public static let parserThrows = StreamParsingError(.parserThrows)

  private let kind: Kind

  private init(_ kind: Kind) {
    self.kind = kind
  }
}
