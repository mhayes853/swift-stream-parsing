// MARK: - StreamParseable

public protocol StreamParseable {
  associatedtype Partial: StreamActionReducer
}

// MARK: - StreamParseableReducer

public protocol StreamParseableReducer: StreamActionReducer
where StreamAction == DefaultStreamAction {
  init(action: DefaultStreamAction) throws
}

// MARK: - StreamParseableError

public struct StreamParseableError: Error, Hashable {
  private let action: DefaultStreamAction

  public static func unsupportedAction(_ action: DefaultStreamAction) -> Self {
    Self(action: action)
  }
}
