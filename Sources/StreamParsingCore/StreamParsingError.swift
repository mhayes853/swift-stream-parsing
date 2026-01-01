public struct StreamParsingError: Error, Hashable {
  private enum Storage: Hashable {
    case unsupportedAction(StreamAction)
    case invalidValue(StreamedValue)
  }

  private let storage: Storage

  public static func unsupportedAction(_ action: StreamAction) -> Self {
    Self(storage: .unsupportedAction(action))
  }

  public static func invalidValue(_ value: StreamedValue) -> Self {
    Self(storage: .invalidValue(value))
  }
}
