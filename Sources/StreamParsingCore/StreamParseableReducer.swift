// MARK: - StreamParseableReducer

public protocol StreamParseableReducer {
  static func initialReduceableValue() -> Self
  static func registerHandlers<Handlers: StreamParserHandlers<Self>>(
    in handlers: inout Handlers
  )
}

// MARK: - Default Initial Values

extension StreamParseableReducer where Self: BinaryInteger {
  public static func initialReduceableValue() -> Self {
    Self()
  }
}

extension StreamParseableReducer where Self: BinaryFloatingPoint {
  public static func initialReduceableValue() -> Self {
    .zero
  }
}
