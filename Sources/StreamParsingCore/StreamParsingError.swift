/// Signals errors raised by stream parsing operations.
public struct StreamParsingError: Error, Hashable {
  private enum Kind: Hashable {
    case multipleSubscribers
    case parserFinished
    case parserFailed
    case incompleteValue
  }

  /// Thrown when more than one iterator attempts to consume an async partials sequence.
  public static let multipleSubscribers = StreamParsingError(.multipleSubscribers)

  // Thrown when a finished stream receives more bytes or is finished again. Not public: every public
  // way to finish a stream consumes it or re-arms it, so only the library's own iterators, which
  // finish a stream they store, can reach a finished one, and they stop before they would.
  @usableFromInline static let parserFinished = StreamParsingError(.parserFinished)

  /// Thrown when a stream is used again after its parser failed.
  ///
  /// The failure itself is thrown once, from the call that provoked it. After that every call
  /// throws this until ``PartialsStream/reset(to:)`` re-arms the stream.
  public static let parserFailed = StreamParsingError(.parserFailed)

  /// Thrown by ``PartialsStream/finish()`` when the document ended in a valid state that does not
  /// describe a whole value: ``StreamParseable/init(streamPartial:)`` returned `nil`, because a
  /// member was never produced or holds a value the type cannot represent.
  ///
  /// To fill the missing members with their initial values instead, finish with
  /// ``PartialsStream/finishPartial()`` and convert with ``StreamParseable/init(orInitial:)``.
  public static let incompleteValue = StreamParsingError(.incompleteValue)

  private let kind: Kind

  private init(_ kind: Kind) {
    self.kind = kind
  }
}
