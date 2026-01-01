// MARK: - StreamParseable

public protocol StreamParseable {
  associatedtype Partial: StreamParseableReducer
}

// MARK: - StreamParseableReducer

public protocol StreamParseableReducer: StreamActionReducer {
  static func initialReduceableValue() -> Self
}

// MARK: - Default Initial Values

extension StreamParseableReducer where Self: BinaryInteger {
  public static func initialReduceableValue() -> Self {
    Self()
  }
}

extension StreamParseableReducer where Self: BinaryFloatingPoint {
  public static func initialReduceableValue() -> Self {
    Self(0)
  }
}

// MARK: - StreamParseableError

public struct StreamParseableError: Error, Hashable {
  private let action: StreamAction

  public static func unsupportedAction(_ action: StreamAction) -> Self {
    Self(action: action)
  }
}
