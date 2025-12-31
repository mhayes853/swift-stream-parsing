// MARK: - StreamParseable

public protocol StreamParseable {
  associatedtype Partial: StreamActionReducer
}

// MARK: - StreamParseableReducer

public protocol StreamParseableReducer: StreamActionReducer {
  init(action: StreamAction) throws
}

// MARK: - StreamParseableError

public struct StreamParseableError: Error, Hashable {
  private let action: StreamAction

  public static func unsupportedAction(_ action: StreamAction) -> Self {
    Self(action: action)
  }
}
