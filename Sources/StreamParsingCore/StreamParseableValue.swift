public protocol StreamParseableValue {
  static func initialParseableValue() -> Self
  static func registerHandlers<Handlers: StreamParserHandlers<Self>>(
    in handlers: inout Handlers
  )
}

extension StreamParseableValue where Self: BinaryInteger {
  public static func initialParseableValue() -> Self {
    Self()
  }
}

extension StreamParseableValue where Self: BinaryFloatingPoint {
  public static func initialParseableValue() -> Self {
    .zero
  }
}
