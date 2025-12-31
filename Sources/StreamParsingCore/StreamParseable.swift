// MARK: - StreamParseable

public protocol StreamParseable {
  associatedtype Partial: StreamParseableReducer
}

// MARK: - StreamParseableReducer

public protocol StreamParseableReducer: StreamActionReducer {
  static func initialReduceableValue() -> Self
}

// MARK: - StreamParseableError

public struct StreamParseableError: Error, Hashable {
  private let action: StreamAction

  public static func unsupportedAction(_ action: StreamAction) -> Self {
    Self(action: action)
  }
}
