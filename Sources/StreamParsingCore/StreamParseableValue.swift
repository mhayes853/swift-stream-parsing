/// A type that can be created and updated by a ``StreamParser``.
public protocol StreamParseableValue {
  /// Returns the value state used before any bytes are parsed.
  static func initialParseableValue() -> Self

  /// Registers handlers that map incoming tokens to the associated value.
  static func registerHandlers<Handlers: StreamParserHandlers<Self>>(
    in handlers: inout Handlers
  )
}

extension StreamParseableValue where Self: BinaryInteger {
  /// Provides zero as the default initial value for integer types.
  public static func initialParseableValue() -> Self {
    Self()
  }
}

extension StreamParseableValue where Self: BinaryFloatingPoint {
  /// Provides `0` as the default initial value for floating-point types.
  public static func initialParseableValue() -> Self {
    .zero
  }
}
