public struct StreamParsingError: Error, Hashable {
  private enum Kind: Hashable {
    case parserFinished
  }

  public static let parserFinished = StreamParsingError(.parserFinished)

  private let kind: Kind

  private init(_ kind: Kind) {
    self.kind = kind
  }
}
