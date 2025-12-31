public struct StreamParseableError: Error, Hashable {
  private let action: DefaultStreamAction

  public static func unsupportedAction(_ action: DefaultStreamAction) -> Self {
    Self(action: action)
  }
}
