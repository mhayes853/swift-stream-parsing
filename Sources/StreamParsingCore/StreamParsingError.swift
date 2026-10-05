/// Signals errors raised by stream parsing operations.
public struct StreamParsingError: Error, Hashable {
  private enum Kind: Hashable {
    case multipleSubscribers
    case parserFinished
    case parserFailed
  }

  /// Thrown when more than one iterator attempts to consume an async partials sequence.
  public static let multipleSubscribers = StreamParsingError(.multipleSubscribers)

  /// Thrown when a finished stream receives more bytes or another call to
  /// ``PartialsStream/finish()``.
  public static let parserFinished = StreamParsingError(.parserFinished)

  /// Thrown when a stream is used again after its parser failed.
  ///
  /// The failure itself is thrown once, from the call that provoked it. After that every call
  /// throws this until ``PartialsStream/reset(to:)`` re-arms the stream.
  public static let parserFailed = StreamParsingError(.parserFailed)

  private let kind: Kind

  private init(_ kind: Kind) {
    self.kind = kind
  }
}
